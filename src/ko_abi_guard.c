// SPDX-License-Identifier: GPL-2.0
/*
 * ko_abi_guard - device-side kernel module ABI contract checker and adapter.
 *
 * Android vendor kernels ship /vendor_dlkm modules that were built for exactly
 * the running kernel.  Every one of those modules records the genksyms CRC it
 * expects for each imported symbol, so the union of their __versions and
 * __version_ext_* sections is an authoritative, on-device snapshot of the
 * symbol contract of the kernel that is actually running.
 *
 * This tool uses that snapshot to decide whether one of our own KOs can be
 * loaded on the current kernel, and to adapt a KO whose recorded CRCs were
 * captured against an older vendor build:
 *
 *   scan   - build the device symbol/CRC contract from the vendor modules
 *   check  - report whether a KO matches the running kernel contract
 *   patch  - write an adapted copy of the KO (original file untouched)
 *
 * Adaptation mirrors what the kernel itself accepts:
 *   * a listed symbol whose CRC differs is rewritten to the device CRC, so the
 *     version check is an exact match again;
 *   * a listed symbol that no vendor module resolves cannot be verified, so
 *     its version entry is neutralised (renamed in place).  The kernel then
 *     treats the import as unversioned: check_version() warns once and accepts
 *     it instead of failing the load.  This is the same path KOs already use
 *     for the vendor-owned imports that never carried a device CRC.
 *
 * Nothing here guesses a CRC.  A symbol is either resolved from the running
 * kernel or its version check is dropped.
 */

#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define ARRAY_SIZE(value) (sizeof(value) / sizeof((value)[0]))
#define VERSION_ENTRY_SIZE 64U
#define VERSION_NAME_SIZE 56U
#define MAX_VERMAGIC 256U

static const char *g_program = "ko_abi_guard";
static bool g_verbose;

static void log_line(const char *format, ...)
{
	va_list args;

	va_start(args, format);
	vfprintf(stdout, format, args);
	va_end(args);
	fputc('\n', stdout);
}

static void log_debug(const char *format, ...)
{
	va_list args;

	if (!g_verbose)
		return;
	va_start(args, format);
	vfprintf(stdout, format, args);
	va_end(args);
	fputc('\n', stdout);
}

static void die(const char *format, ...)
{
	va_list args;

	fflush(stdout);
	va_start(args, format);
	vfprintf(stderr, format, args);
	va_end(args);
	fputc('\n', stderr);
	exit(1);
}

static void *xmalloc(size_t size)
{
	void *pointer = malloc(size ? size : 1);

	if (!pointer)
		die("out of memory");
	return pointer;
}

static void *xrealloc(void *pointer, size_t size)
{
	void *result = realloc(pointer, size ? size : 1);

	if (!result)
		die("out of memory");
	return result;
}

/* ------------------------------------------------------------------ */
/* growable string arena                                               */
/* ------------------------------------------------------------------ */

/*
 * Chunked string arena.  Hash map keys point straight into these blocks, so
 * the blocks must never move: growing by realloc would leave every stored key
 * dangling.
 */
struct arena_chunk {
	struct arena_chunk *next;
	size_t used;
	size_t capacity;
	char data[];
};

struct arena {
	struct arena_chunk *head;
};

static char *arena_dup(struct arena *arena, const char *text)
{
	size_t length = strlen(text) + 1;
	struct arena_chunk *chunk = arena->head;
	char *result;

	if (!chunk || chunk->used + length > chunk->capacity) {
		size_t capacity = 1U << 18;

		while (capacity < length)
			capacity *= 2;
		chunk = xmalloc(sizeof(*chunk) + capacity);
		chunk->next = arena->head;
		chunk->used = 0;
		chunk->capacity = capacity;
		arena->head = chunk;
	}
	result = chunk->data + chunk->used;
	memcpy(result, text, length);
	chunk->used += length;
	return result;
}

static void arena_free(struct arena *arena)
{
	while (arena->head) {
		struct arena_chunk *next = arena->head->next;

		free(arena->head);
		arena->head = next;
	}
}

/* ------------------------------------------------------------------ */
/* string hash map                                                     */
/* ------------------------------------------------------------------ */

struct strmap {
	char **keys;
	uint32_t *values;
	uint8_t *state;
	size_t capacity;
	size_t count;
};

static uint64_t hash_string(const char *text)
{
	uint64_t hash = 1469598103934665603ULL;

	while (*text) {
		hash ^= (unsigned char)*text++;
		hash *= 1099511628211ULL;
	}
	return hash;
}

static void strmap_init(struct strmap *map, size_t capacity)
{
	size_t wanted = 1024;

	while (wanted < capacity * 2)
		wanted *= 2;
	map->capacity = wanted;
	map->count = 0;
	map->keys = xmalloc(sizeof(char *) * wanted);
	map->values = xmalloc(sizeof(uint32_t) * wanted);
	map->state = xmalloc(wanted);
	memset(map->state, 0, wanted);
}

static void strmap_grow(struct strmap *map)
{
	struct strmap larger;
	size_t index;

	strmap_init(&larger, map->capacity * 2);
	for (index = 0; index < map->capacity; index++) {
		size_t slot;

		if (map->state[index] != 1)
			continue;
		slot = hash_string(map->keys[index]) & (larger.capacity - 1);
		while (larger.state[slot] == 1)
			slot = (slot + 1) & (larger.capacity - 1);
		larger.state[slot] = 1;
		larger.keys[slot] = map->keys[index];
		larger.values[slot] = map->values[index];
		larger.count++;
	}
	free(map->keys);
	free(map->values);
	free(map->state);
	*map = larger;
}

static int strmap_lookup(const struct strmap *map, const char *key, uint32_t *value)
{
	size_t slot = hash_string(key) & (map->capacity - 1);

	while (map->state[slot] != 0) {
		if (map->state[slot] == 1 && strcmp(map->keys[slot], key) == 0) {
			if (value)
				*value = map->values[slot];
			return 1;
		}
		slot = (slot + 1) & (map->capacity - 1);
	}
	return 0;
}

static void strmap_insert(struct strmap *map, const char *key, uint32_t value)
{
	size_t slot;

	if (map->count * 4 >= map->capacity * 3)
		strmap_grow(map);
	slot = hash_string(key) & (map->capacity - 1);
	while (map->state[slot] != 0) {
		if (map->state[slot] == 1 && strcmp(map->keys[slot], key) == 0) {
			map->values[slot] = value;
			return;
		}
		slot = (slot + 1) & (map->capacity - 1);
	}
	map->state[slot] = 1;
	map->keys[slot] = (char *)key;
	map->values[slot] = value;
	map->count++;
}

/* ------------------------------------------------------------------ */
/* file helpers                                                        */
/* ------------------------------------------------------------------ */

static uint8_t *read_file(const char *path, size_t *size_out)
{
	FILE *handle = fopen(path, "rb");
	uint8_t *buffer;
	size_t size;

	if (!handle)
		return NULL;
	if (fseek(handle, 0, SEEK_END) != 0) {
		fclose(handle);
		return NULL;
	}
	size = (size_t)ftell(handle);
	if (fseek(handle, 0, SEEK_SET) != 0) {
		fclose(handle);
		return NULL;
	}
	buffer = xmalloc(size + 1);
	if (size && fread(buffer, 1, size, handle) != size) {
		fclose(handle);
		free(buffer);
		return NULL;
	}
	buffer[size] = 0;
	fclose(handle);
	*size_out = size;
	return buffer;
}

static bool write_file(const char *path, const uint8_t *data, size_t size)
{
	FILE *handle = fopen(path, "wb");
	bool ok;

	if (!handle)
		return false;
	ok = size == 0 || fwrite(data, 1, size, handle) == size;
	if (fclose(handle) != 0)
		ok = false;
	return ok;
}

/* ------------------------------------------------------------------ */
/* ELF parsing                                                         */
/* ------------------------------------------------------------------ */

struct section {
	char name[64];
	uint32_t type;
	uint64_t offset;
	uint64_t size;
	uint64_t link;
	uint64_t entsize;
};

struct ko_view {
	uint8_t *data;
	size_t size;
	struct section *sections;
	size_t section_count;
	char vermagic[MAX_VERMAGIC];
};

static uint32_t read_u16(const uint8_t *data, uint64_t offset)
{
	return (uint32_t)data[offset] | ((uint32_t)data[offset + 1] << 8);
}

static uint32_t read_u32(const uint8_t *data, uint64_t offset)
{
	return (uint32_t)data[offset] | ((uint32_t)data[offset + 1] << 8) |
	       ((uint32_t)data[offset + 2] << 16) | ((uint32_t)data[offset + 3] << 24);
}

static uint64_t read_u64(const uint8_t *data, uint64_t offset)
{
	return (uint64_t)read_u32(data, offset) |
	       ((uint64_t)read_u32(data, offset + 4) << 32);
}

static const struct section *find_section(const struct ko_view *view, const char *name)
{
	size_t index;

	for (index = 0; index < view->section_count; index++) {
		if (strcmp(view->sections[index].name, name) == 0)
			return &view->sections[index];
	}
	return NULL;
}

static void load_ko(struct ko_view *view, const char *path)
{
	const uint8_t *shstrtab;
	uint64_t shoff;
	uint64_t shstrndx;
	uint64_t shentsize;
	uint64_t shnum;
	uint64_t index;

	memset(view, 0, sizeof(*view));
	view->data = read_file(path, &view->size);
	if (!view->data)
		die("cannot read %s: %s", path, strerror(errno));
	if (view->size < 0x40 || memcmp(view->data, "\177ELF", 4) != 0 ||
	    view->data[4] != 2 || view->data[5] != 1)
		die("%s is not a little-endian ELF64 object", path);

	shoff = read_u64(view->data, 0x28);
	shentsize = read_u16(view->data, 0x3a);
	shnum = read_u16(view->data, 0x3c);
	shstrndx = read_u16(view->data, 0x3e);
	if (shentsize < 64 || shnum == 0 || shstrndx >= shnum ||
	    shoff + shentsize * shnum > view->size)
		die("%s has invalid ELF section headers", path);

	view->section_count = (size_t)shnum;
	view->sections = xmalloc(sizeof(*view->sections) * view->section_count);
	for (index = 0; index < shnum; index++) {
		uint64_t header = shoff + index * shentsize;
		struct section *section = &view->sections[index];

		section->offset = read_u64(view->data, header + 0x18);
		section->size = read_u64(view->data, header + 0x20);
		section->link = read_u32(view->data, header + 0x28);
		section->type = read_u32(view->data, header + 4);
		section->entsize = read_u64(view->data, header + 0x38);
		/* SHT_NOBITS (8) sections such as .bss have no file backing, so
		 * their offset may legitimately point past the end of the file. */
		if (section->type != 8 && section->offset + section->size > view->size)
			die("%s section %llu exceeds the file size", path,
			    (unsigned long long)index);
	}

	shstrtab = view->data + view->sections[shstrndx].offset;
	for (index = 0; index < shnum; index++) {
		uint64_t name_offset = read_u32(view->data, shoff + index * shentsize);
		size_t limit = (size_t)view->sections[shstrndx].size;
		size_t length = 0;

		if (name_offset >= limit)
			continue;
		while (name_offset + length < limit && shstrtab[name_offset + length])
			length++;
		if (length >= sizeof(view->sections[index].name))
			length = sizeof(view->sections[index].name) - 1;
		memcpy(view->sections[index].name, shstrtab + name_offset, length);
		view->sections[index].name[length] = 0;
	}

	for (index = 0; index < view->section_count; index++) {
		const struct section *section = &view->sections[index];
		const char *found;

		if (strcmp(section->name, ".modinfo") != 0)
			continue;
		found = (const char *)(view->data + section->offset);
		while ((size_t)(found - (const char *)(view->data + section->offset)) <
		       section->size) {
			if (strncmp(found, "vermagic=", 9) == 0) {
				snprintf(view->vermagic, sizeof(view->vermagic), "%s",
					 found + 9);
				break;
			}
			found += strlen(found) + 1;
		}
	}
}

/*
 * Version information layout of an imported symbol.  The kernel prefers the
 * extended sections whenever they exist, so patches must keep both copies in
 * sync; with extended modversions the legacy section is dead weight.
 */
struct version_entry {
	char name[256];
	uint32_t crc;
	uint64_t crc_offset;   /* file offset of the recorded CRC */
	uint64_t name_offset;  /* file offset of the recorded name */
	bool extended;
};

static size_t ko_version_count(const struct ko_view *view)
{
	const struct section *ext_crcs = find_section(view, "__version_ext_crcs");

	if (ext_crcs)
		return (size_t)(ext_crcs->size / 4);
	{
		const struct section *legacy = find_section(view, "__versions");

		return legacy ? (size_t)(legacy->size / VERSION_ENTRY_SIZE) : 0;
	}
}

static bool ko_version_get(const struct ko_view *view, size_t index,
			   struct version_entry *entry)
{
	const struct section *ext_names = find_section(view, "__version_ext_names");
	const struct section *ext_crcs = find_section(view, "__version_ext_crcs");

	memset(entry, 0, sizeof(*entry));
	if (ext_crcs && ext_names) {
		const char *name = (const char *)(view->data + ext_names->offset);
		size_t consumed = 0;
		size_t offset = 0;

		while (offset < index) {
			if (consumed >= ext_names->size)
				return false;
			consumed += strlen(name + consumed) + 1;
			offset++;
		}
		if (consumed >= ext_names->size)
			return false;
		snprintf(entry->name, sizeof(entry->name), "%s", name + consumed);
		entry->crc = read_u32(view->data, ext_crcs->offset + index * 4);
		entry->crc_offset = ext_crcs->offset + index * 4;
		entry->name_offset = ext_names->offset + consumed;
		entry->extended = true;
		return true;
	}
	{
		const struct section *legacy = find_section(view, "__versions");
		uint64_t base;

		if (!legacy)
			return false;
		base = legacy->offset + index * VERSION_ENTRY_SIZE;
		entry->crc = read_u32(view->data, base);
		entry->crc_offset = base;
		entry->name_offset = base + 8;
		snprintf(entry->name, sizeof(entry->name), "%s",
			 (const char *)(view->data + base + 8));
		entry->extended = false;
		return true;
	}
}

/*
 * Imported symbol names, taken from the symbol table.  Only undefined symbols
 * are relevant: they are what the kernel must resolve from vmlinux or from
 * another module.
 */
static void ko_collect_imports(struct ko_view *view, struct strmap *imports,
			       struct arena *arena)
{
	size_t index;

	for (index = 0; index < view->section_count; index++) {
		const struct section *symbols = &view->sections[index];
		const struct section *strings;
		uint64_t count;
		uint64_t entry;

		if (strcmp(symbols->name, ".symtab") != 0 || symbols->entsize == 0)
			continue;
		if (symbols->link >= view->section_count)
			continue;
		strings = &view->sections[symbols->link];
		count = symbols->size / symbols->entsize;
		for (entry = 0; entry < count; entry++) {
			uint64_t base = symbols->offset + entry * symbols->entsize;
			uint32_t name_offset = read_u32(view->data, base);
			uint16_t section_index = (uint16_t)read_u16(view->data, base + 6);
			const char *name;

			if (section_index != 0 || name_offset >= strings->size)
				continue;
			name = (const char *)(view->data + strings->offset + name_offset);
			if (!*name)
				continue;
			if (!strmap_lookup(imports, name, NULL))
				strmap_insert(imports, arena_dup(arena, name), 1);
		}
	}
}

/* ------------------------------------------------------------------ */
/* kernel side information                                             */
/* ------------------------------------------------------------------ */

static void kallsyms_load(struct strmap *symbols, struct arena *arena, const char *path)
{
	FILE *handle = fopen(path, "r");
	char line[512];

	if (!handle) {
		log_debug("kallsyms: cannot read %s: %s", path, strerror(errno));
		return;
	}
	while (fgets(line, sizeof(line), handle)) {
		char *first = strchr(line, ' ');
		char *second;
		char *third;
		char *end;

		if (!first)
			continue;
		second = strchr(first + 1, ' ');
		if (!second)
			continue;
		third = second + 1;
		while (*third == ' ')
			third++;
		end = third;
		while (*end && *end != '\n' && *end != '\r' && *end != '\t' && *end != ' ')
			end++;
		*end = 0;
		if (*third && !strmap_lookup(symbols, third, NULL))
			strmap_insert(symbols, arena_dup(arena, third), 1);
	}
	fclose(handle);
}

static int contract_from_modules(const char *modules_dir, struct strmap *contract,
				 struct strmap *providers, struct arena *arena,
				 int *module_count)
{
	char path[4096];
	DIR *handle;
	struct dirent *entry;

	snprintf(path, sizeof(path), "%s/lib/modules", modules_dir);
	handle = opendir(path);
	if (!handle)
		return -1;
	while ((entry = readdir(handle))) {
		char file[4352];
		struct ko_view view;
		size_t index;
		size_t count;
		const char *dot = strrchr(entry->d_name, '.');

		if (!dot || strcmp(dot, ".ko") != 0)
			continue;
		snprintf(file, sizeof(file), "%s/%s", path, entry->d_name);
		load_ko(&view, file);
		count = ko_version_count(&view);
		for (index = 0; index < count; index++) {
			struct version_entry version;

			if (!ko_version_get(&view, index, &version))
				continue;
			if (!version.crc)
				continue;
			if (!strmap_lookup(contract, version.name, NULL))
				strmap_insert(contract, arena_dup(arena, version.name),
					      version.crc);
		}
		if (providers) {
			size_t section_index;

			for (section_index = 0; section_index < view.section_count;
			     section_index++) {
				const struct section *symbols = &view.sections[section_index];
				const struct section *strings;
				uint64_t symbols_count;
				uint64_t symbol;

				if (strcmp(symbols->name, ".symtab") != 0 ||
				    symbols->entsize == 0 ||
				    symbols->link >= view.section_count)
					continue;
				strings = &view.sections[symbols->link];
				symbols_count = symbols->size / symbols->entsize;
				for (symbol = 0; symbol < symbols_count; symbol++) {
					uint64_t base =
						symbols->offset + symbol * symbols->entsize;
					uint32_t name_offset = read_u32(view.data, base);
					uint16_t section_link =
						(uint16_t)read_u16(view.data, base + 6);
					uint8_t info = view.data[base + 4];
					const char *name;

					if (section_link == 0 || !(info & 0x10) ||
					    name_offset >= strings->size)
						continue;
					name = (const char *)(view.data + strings->offset +
							      name_offset);
					if (!*name ||
					    strmap_lookup(providers, name, NULL))
						continue;
					strmap_insert(providers, arena_dup(arena, name), 1);
				}
			}
		}
		free(view.data);
		free(view.sections);
		(*module_count)++;
	}
	closedir(handle);
	return 0;
}

static void contract_load_file(struct strmap *contract, struct arena *arena,
			       const char *path)
{
	FILE *handle = fopen(path, "r");
	char line[512];

	if (!handle)
		die("cannot read contract %s", path);
	while (fgets(line, sizeof(line), handle)) {
		char *tab = strchr(line, '\t');
		char *end;
		unsigned long value;

		if (!tab)
			continue;
		*tab = 0;
		end = tab + 1;
		while (*end == ' ')
			end++;
		value = strtoul(end, NULL, 16);
		if (!value)
			continue;
		if (!strmap_lookup(contract, line, NULL))
			strmap_insert(contract, arena_dup(arena, line), (uint32_t)value);
	}
	fclose(handle);
}

static void contract_write_file(const struct strmap *contract, const char *path)
{
	FILE *handle = fopen(path, "w");
	size_t index;

	if (!handle)
		die("cannot write contract %s", path);
	for (index = 0; index < contract->capacity; index++) {
		if (contract->state[index] != 1)
			continue;
		fprintf(handle, "%s\t0x%08x\n", contract->keys[index],
			contract->values[index]);
	}
	fclose(handle);
}

/* ------------------------------------------------------------------ */
/* commands                                                            */
/* ------------------------------------------------------------------ */

static const char *basename_of(const char *path)
{
	const char *slash = strrchr(path, '/');

	return slash ? slash + 1 : path;
}

static int command_scan(int argc, char **argv)
{
	struct arena arena = { 0 };
	struct strmap contract;
	struct strmap providers;
	const char *dirs[8];
	size_t dir_count = 0;
	const char *output = NULL;
	const char *providers_output = NULL;
	int modules = 0;
	size_t index;

	strmap_init(&contract, 1 << 16);
	strmap_init(&providers, 1 << 16);
	for (index = 0; index < (size_t)argc; index++) {
		if (strcmp(argv[index], "--out") == 0 && index + 1 < (size_t)argc)
			output = argv[++index];
		else if (strcmp(argv[index], "--out-providers") == 0 &&
			 index + 1 < (size_t)argc)
			providers_output = argv[++index];
		else if (strcmp(argv[index], "--verbose") == 0)
			g_verbose = true;
		else if (dir_count < ARRAY_SIZE(dirs))
			dirs[dir_count++] = argv[index];
	}
	if (dir_count == 0) {
		dirs[dir_count++] = "/vendor_dlkm";
		dirs[dir_count++] = "/system_dlkm";
	}
	for (index = 0; index < dir_count; index++) {
		if (contract_from_modules(dirs[index], &contract, &providers, &arena,
					  &modules) != 0)
			log_debug("scan: no modules under %s", dirs[index]);
	}
	if (!modules)
		die("scan: no vendor modules found");
	log_debug("scan: parsed %d vendor modules", modules);
	if (output)
		contract_write_file(&contract, output);
	else if (!providers_output) {
		size_t slot;

		for (slot = 0; slot < contract.capacity; slot++) {
			if (contract.state[slot] != 1)
				continue;
			printf("%s\t0x%08x\n", contract.keys[slot],
			       contract.values[slot]);
		}
	}
	if (providers_output)
		contract_write_file(&providers, providers_output);
	log_line("CONTRACT_MODULES=%d", modules);
	log_line("CONTRACT_SYMBOLS=%zu", contract.count);
	log_line("PROVIDER_SYMBOLS=%zu", providers.count);
	return 0;
}

struct analysis {
	bool fatal;
	bool needs_patch;
	unsigned int patched;
	unsigned int neutralised;
	unsigned int missing;
	unsigned int unresolved;
	char first_reason[128];
};

static void analyse_ko(const char *ko_path, const struct strmap *contract,
		       const struct strmap *kallsyms, bool with_kallsyms,
		       const struct strmap *providers, struct analysis *result,
		       const char **name_out)
{
	struct ko_view view;
	struct arena arena = { 0 };
	struct strmap imports;
	size_t count;
	size_t index;

	load_ko(&view, ko_path);
	*name_out = basename_of(ko_path);
	strmap_init(&imports, 1 << 12);
	ko_collect_imports(&view, &imports, &arena);
	count = ko_version_count(&view);
	for (index = 0; index < count; index++) {
		struct version_entry version;

		if (!ko_version_get(&view, index, &version))
			continue;
		if (strmap_lookup(contract, version.name, NULL)) {
			uint32_t expected = 0;

			strmap_lookup(contract, version.name, &expected);
			if (expected != version.crc) {
				result->needs_patch = true;
				result->patched++;
				log_line("ENTRY symbol=%s ko=0x%08x device=0x%08x "
					 "action=patch", version.name, version.crc,
					 expected);
			}
			continue;
		}
		if (with_kallsyms && strmap_lookup(kallsyms, version.name, NULL)) {
			result->needs_patch = true;
			result->neutralised++;
			log_line("ENTRY symbol=%s ko=0x%08x device=- "
				 "action=neutralise reason=no-device-crc",
				 version.name, version.crc);
			continue;
		}
		result->needs_patch = true;
		result->unresolved++;
		log_line("ENTRY symbol=%s ko=0x%08x device=- "
			 "action=neutralise reason=not-in-kallsyms",
			 version.name, version.crc);
	}

	for (index = 0; index < imports.capacity; index++) {
		if (imports.state[index] != 1)
			continue;
		if (strmap_lookup(contract, imports.keys[index], NULL)) {
			if (g_verbose)
				log_line("IMPORT symbol=%s present=yes",
					 imports.keys[index]);
			continue;
		}
		if (with_kallsyms && strmap_lookup(kallsyms, imports.keys[index], NULL)) {
			if (g_verbose)
				log_line("IMPORT symbol=%s present=yes",
					 imports.keys[index]);
			continue;
		}
		if (providers && strmap_lookup(providers, imports.keys[index], NULL)) {
			if (g_verbose)
				log_line("IMPORT symbol=%s present=vendor-build",
					 imports.keys[index]);
			continue;
		}
		{
			result->missing++;
			log_line("IMPORT symbol=%s present=no", imports.keys[index]);
		}
	}
	if (result->missing) {
		result->fatal = true;
		snprintf(result->first_reason, sizeof(result->first_reason),
			 "missing-symbol");
	}
	free(imports.keys);
	free(imports.values);
	free(imports.state);
	arena_free(&arena);
	free(view.data);
	free(view.sections);
}

static bool neutralise_entry(struct ko_view *view, const struct version_entry *entry)
{
	const struct section *legacy = find_section(view, "__versions");
	bool changed = false;

	/*
	 * '#' cannot appear in a kernel symbol name, so a renamed entry never
	 * matches again and the kernel treats the import as unversioned
	 * (check_version() warns once and accepts it).
	 */
	if (legacy) {
		uint8_t *cursor;

		for (cursor = view->data + legacy->offset;
		     (size_t)(cursor - view->data) < legacy->offset + legacy->size;
		     cursor += VERSION_ENTRY_SIZE) {
			if (strcmp((const char *)(cursor + 8), entry->name) != 0)
				continue;
			cursor[8] = '#';
			changed = true;
			break;
		}
	}
	if (entry->extended) {
		uint8_t *name = view->data + entry->name_offset;

		if (*name) {
			*name = '#';
			changed = true;
		}
	}
	return changed;
}

static int command_check_or_patch(bool patch, int argc, char **argv)
{
	struct arena arena = { 0 };
	struct strmap contract;
	struct strmap symbols;
	struct strmap providers;
	const char *contract_path = NULL;
	const char *providers_path = NULL;
	const char *kallsyms_path = "/proc/kallsyms";
	const char *modules_dir = "/vendor_dlkm";
	const char *output = NULL;
	const char *ko_path = NULL;
	struct analysis result;
	const char *ko_name = NULL;
	struct ko_view view;
	size_t count;
	size_t index;
	int modules = 0;

	memset(&result, 0, sizeof(result));
	strmap_init(&contract, 1 << 16);
	strmap_init(&symbols, 1 << 17);
	strmap_init(&providers, 1 << 16);
	for (index = 0; index < (size_t)argc; index++) {
		if (strcmp(argv[index], "--contract") == 0 && index + 1 < (size_t)argc)
			contract_path = argv[++index];
		else if (strcmp(argv[index], "--providers") == 0 &&
			 index + 1 < (size_t)argc)
			providers_path = argv[++index];
		else if (strcmp(argv[index], "--kallsyms") == 0 && index + 1 < (size_t)argc)
			kallsyms_path = argv[++index];
		else if (strcmp(argv[index], "--modules-dir") == 0 &&
			 index + 1 < (size_t)argc)
			modules_dir = argv[++index];
		else if (strcmp(argv[index], "--output") == 0 && index + 1 < (size_t)argc)
			output = argv[++index];
		else if (strcmp(argv[index], "--verbose") == 0)
			g_verbose = true;
		else if (argv[index][0] != '-')
			ko_path = argv[index];
	}
	if (!ko_path)
		die("%s: a module path is required", g_program);
	if (contract_path) {
		contract_load_file(&contract, &arena, contract_path);
	} else {
		if (contract_from_modules(modules_dir, &contract, &providers, &arena,
					  &modules) != 0)
			die("cannot read modules under %s", modules_dir);
	}
	if (providers_path)
		contract_load_file(&providers, &arena, providers_path);
	kallsyms_load(&symbols, &arena, kallsyms_path);
	log_debug("contract=%zu symbols, kallsyms=%zu symbols", contract.count,
		  symbols.count);

	analyse_ko(ko_path, &contract, &symbols, symbols.count != 0,
		   providers.count ? &providers : NULL, &result, &ko_name);

	if (patch && !result.fatal) {
		size_t patched_count = 0;
		size_t neutralised_count = 0;

		load_ko(&view, ko_path);
		count = ko_version_count(&view);
		for (index = 0; index < count; index++) {
			struct version_entry version;
			uint32_t expected = 0;

			if (!ko_version_get(&view, index, &version))
				continue;
			if (strmap_lookup(&contract, version.name, &expected) && expected) {
				if (expected == version.crc)
					continue;
				view.data[version.crc_offset] = (uint8_t)(expected & 0xff);
				view.data[version.crc_offset + 1] =
					(uint8_t)((expected >> 8) & 0xff);
				view.data[version.crc_offset + 2] =
					(uint8_t)((expected >> 16) & 0xff);
				view.data[version.crc_offset + 3] =
					(uint8_t)((expected >> 24) & 0xff);
				patched_count++;
				continue;
			}
			if (strmap_lookup(&contract, version.name, NULL))
				continue;
			if (neutralise_entry(&view, &version))
				neutralised_count++;
		}
		if (!output)
			die("patch: --output is required");
		if (!write_file(output, view.data, view.size))
			die("patch: cannot write %s", output);
		log_line("PATCHED_CRC=%zu", patched_count);
		log_line("NEUTRALISED=%zu", neutralised_count);
		free(view.data);
		free(view.sections);
	}

	if (result.fatal) {
		log_line("KO_ABI_CHECK=FAIL");
		log_line("reason=FAIL_MISSING_SYMBOL count=%u", result.missing);
		return 1;
	}
	if (result.needs_patch) {
		log_line("KO_ABI_CHECK=%s", patch ? "PATCHED" : "NEEDS_PATCH");
		log_line("reason=CRC_CONTRACT_DRIFT patched=%u neutralised=%u "
			 "unresolved=%u", result.patched, result.neutralised,
			 result.unresolved);
		return patch ? 0 : 3;
	}
	log_line("KO_ABI_CHECK=PASS");
	return 0;
}

static void usage(void)
{
	fprintf(stderr,
		"Usage: %s scan [--out FILE] [--verbose] [MODULES_DIR...]\n"
		"       %s check [--contract FILE] [--kallsyms FILE]\n"
		"                    [--modules-dir DIR] [--verbose] KO\n"
		"       %s patch [--contract FILE] [--kallsyms FILE]\n"
		"                    [--modules-dir DIR] --output OUT KO\n",
		g_program, g_program, g_program);
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		usage();
		return 2;
	}
	if (strcmp(argv[1], "scan") == 0)
		return command_scan(argc - 2, argv + 2);
	if (strcmp(argv[1], "check") == 0)
		return command_check_or_patch(false, argc - 2, argv + 2);
	if (strcmp(argv[1], "patch") == 0)
		return command_check_or_patch(true, argc - 2, argv + 2);
	usage();
	return 2;
}
