# Add or normalize only the HMBIRD node in a structurally identified DTBO
# overlay.  This file intentionally does not inspect model names, project IDs,
# panel names, display manifests, or any display timing data.

function brace_delta(text, copy, opens, closes) {
    copy = text
    opens = gsub(/\{/, "{", copy)
    copy = text
    closes = gsub(/\}/, "}", copy)
    return opens - closes
}

function leading_space(text) {
    match(text, /^[ \t]*/)
    return substr(text, 1, RLENGTH)
}

function find_block_end(start, limit, depth, i) {
    depth = 0
    for (i = start; i <= limit; i++) {
        depth += brace_delta(lines[i])
        if (i > start && depth == 0)
            return i
    }
    return 0
}

function is_fragment(text) {
    return text ~ /^[ \t]*fragment@[A-Za-z0-9,_-]+[ \t]*\{/
}

function is_overlay(text) {
    return text ~ /^[ \t]*__overlay__[ \t]*\{/
}

function is_hmbird(text) {
    return text ~ /^[ \t]*oplus,hmbird[ \t]*\{/
}

function is_reboot_reason(text) {
    return text ~ /^[ \t]*([A-Za-z0-9,_-]+:[ \t]*)?reboot_reason([@A-Za-z0-9,_-]*)?[ \t]*\{/
}

function is_oplus_sim_detect(text) {
    return text ~ /^[ \t]*oplus_sim_detect[ \t]*\{/
}

function is_oplus_gpio(text) {
    return text ~ /^[ \t]*oplus-gpio[ \t]*\{/
}

function is_shell_node(text) {
    return text ~ /^[ \t]*shell_(front|frame|back)[ \t]*\{/
}

function direct_child_start(parent_start, parent_end, matcher, parent_depth,
                             i, before, count, found) {
    parent_depth = depth_before[parent_start]
    count = 0
    found = 0
    for (i = parent_start + 1; i < parent_end; i++) {
        before = depth_before[i]
        if (before == parent_depth + 1 && lines[i] ~ matcher) {
            count++
            found = i
        }
    }
    direct_count = count
    return found
}

function overlay_has_gpio(overlay_start, overlay_end, gpio_start, gpio_end,
                          count, i) {
    gpio_start = direct_child_start(overlay_start, overlay_end,
                                    "^[ \\t]*oplus-gpio[ \\t]*\\{", 0)
    count = direct_count
    if (count != 1)
        return 0
    gpio_end = find_block_end(gpio_start, overlay_end)
    if (!gpio_end)
        return 0
    for (i = gpio_start; i <= gpio_end; i++) {
        if (lines[i] ~ /compatible[ \t]*=[ \t]*"oplus,oplus-gpio"[ \t]*;/)
            return 1
    }
    return 0
}

function type_is(type_value, node_start, node_end, i) {
    for (i = node_start; i <= node_end; i++) {
        if (lines[i] ~ /type[ \t]*=[ \t]*"HMBIRD_EXT"[ \t]*;/) {
            if (type_value != "HMBIRD_EXT")
                return 0
            type_seen = 1
        }
        if (lines[i] ~ /type[ \t]*=[ \t]*"HMBIRD_OGKI"[ \t]*;/) {
            if (type_value != "HMBIRD_OGKI")
                return 0
            type_seen = 1
        }
    }
    return type_seen == 1
}

{
    lines[NR] = $0
    depth_before[NR] = current_depth
    current_depth += brace_delta($0)
}

END {
    if (requested_type != "HMBIRD_EXT" && requested_type != "HMBIRD_OGKI")
        exit 4

    # Collect only real, top-level fragments.  __symbols__, __fixups__ and
    # __local_fixups__ contain path metadata that must never be patched.
    fragment_count = 0
    for (i = 1; i <= NR; i++) {
        if (depth_before[i] == 1 && is_fragment(lines[i])) {
            fragment_count++
            fragment_start[fragment_count] = i
            fragment_end[fragment_count] = find_block_end(i, NR)
            if (!fragment_end[fragment_count])
                exit 4
        }
    }
    if (fragment_count == 0)
        exit 3

    overlay_count = 0
    for (f = 1; f <= fragment_count; f++) {
        fs = fragment_start[f]
        fe = fragment_end[f]
        os = direct_child_start(fs, fe, "^[ \\t]*__overlay__[ \\t]*\\{", 0)
        oc = direct_count
        if (oc != 1)
            continue
        oe = find_block_end(os, fe)
        if (!oe)
            exit 4
        overlay_count++
        overlay_fragment[overlay_count] = f
        overlay_start[overlay_count] = os
        overlay_end[overlay_count] = oe
    }
    if (overlay_count == 0)
        exit 3

    # Count direct HMBIRD nodes in real overlays, and reject a second node
    # outside the selected overlay scope.
    all_hmbird_count = 0
    existing_overlay = 0
    existing_hmbird_start = 0
    existing_hmbird_end = 0
    for (o = 1; o <= overlay_count; o++) {
        hs = direct_child_start(overlay_start[o], overlay_end[o],
                                "^[ \\t]*oplus,hmbird[ \\t]*\\{", 0)
        hc = direct_count
        if (hc > 1)
            exit 4
        if (hc == 1) {
            all_hmbird_count++
            if (existing_overlay != 0)
                exit 4
            existing_overlay = o
            existing_hmbird_start = hs
            existing_hmbird_end = find_block_end(hs, overlay_end[o])
            if (!existing_hmbird_end)
                exit 4
            type_seen = 0
            if (!type_is(requested_type, existing_hmbird_start,
                         existing_hmbird_end))
                exit 4
        }
    }
    if (all_hmbird_count > 1)
        exit 4

    if (requested_type == "HMBIRD_OGKI") {
        # OGKI is deliberately tied to the user-specified fragment@15 shape.
        target_fragment = 0
        for (f = 1; f <= fragment_count; f++) {
            if (fragment_start[f] <= NR &&
                lines[fragment_start[f]] ~ /^[ \t]*fragment@15[ \t]*\{/) {
                if (target_fragment != 0)
                    exit 4
                target_fragment = f
            }
        }
        if (target_fragment == 0)
            exit 3

        target_overlay = 0
        for (o = 1; o <= overlay_count; o++) {
            if (overlay_fragment[o] == target_fragment) {
                if (target_overlay != 0)
                    exit 4
                target_overlay = o
            }
        }
        if (target_overlay == 0)
            exit 4

        rs = direct_child_start(overlay_start[target_overlay],
                                overlay_end[target_overlay],
                                "^[ \\t]*([A-Za-z0-9,_-]+:[ \\t]*)?reboot_reason([@A-Za-z0-9,_-]*)?[ \\t]*\\{", 0)
        rc = direct_count
        if (rc != 1)
            exit 4
        if (existing_overlay != 0 && existing_overlay != target_overlay)
            exit 4
        insert_at = rs
        insert_indent = leading_space(lines[rs])
    } else {
        # EXT normally has a board-level overlay containing oplus_sim_detect.
        # That anchor is preferred when present, but is not required.  A
        # unique oplus-gpio node is the device-agnostic fallback; both are
        # unrelated to panel names and display timing.
        sim_count = 0
        sim_overlay = 0
        gpio_count = 0
        gpio_overlay = 0
        shell_count = 0
        shell_overlay = 0
        for (o = 1; o <= overlay_count; o++) {
            ss = direct_child_start(overlay_start[o], overlay_end[o],
                                    "^[ \\t]*oplus_sim_detect[ \\t]*\\{", 0)
            if (direct_count == 1) {
                sim_count++
                sim_overlay = o
            } else if (direct_count > 1) {
                exit 4
            }
            if (overlay_has_gpio(overlay_start[o], overlay_end[o])) {
                gpio_count++
                gpio_overlay = o
            }
            sh = direct_child_start(overlay_start[o], overlay_end[o],
                                    "^[ \\t]*shell_(front|frame|back)[ \\t]*\\{", 0)
            if (direct_count > 0) {
                shell_count++
                shell_overlay = o
            }
        }
        if (existing_overlay != 0) {
            target_overlay = existing_overlay
        } else if (sim_count == 1) {
            target_overlay = sim_overlay
        } else if (sim_count > 1) {
            exit 4
        } else if (gpio_count == 1) {
            target_overlay = gpio_overlay
        } else if (gpio_count > 1) {
            exit 4
        } else {
            # Shell thermal nodes are a weaker fallback and only qualify when
            # they identify one overlay; otherwise fail closed.
            if (shell_count != 1)
                exit 3
            target_overlay = shell_overlay
        }
        if (existing_overlay != 0 && existing_overlay != target_overlay)
            exit 4

        if (existing_overlay != 0) {
            insert_at = existing_hmbird_start
            insert_indent = leading_space(lines[existing_hmbird_start])
        } else {
            sim_start = direct_child_start(overlay_start[target_overlay],
                                           overlay_end[target_overlay],
                                           "^[ \\t]*oplus_sim_detect[ \\t]*\\{", 0)
            if (direct_count == 1) {
                insert_at = sim_start
                insert_indent = leading_space(lines[sim_start])
            } else {
                insert_at = overlay_end[target_overlay]
                insert_indent = leading_space(lines[overlay_end[target_overlay]]) "\t"
            }
        }
    }

    for (i = 1; i <= NR; i++) {
        if (i == insert_at) {
            print insert_indent "oplus,hmbird {"
            if (requested_type == "HMBIRD_OGKI") {
                print insert_indent "\tversion_type {"
            } else {
                print insert_indent "\tconfig_type {"
            }
            print insert_indent "\t\ttype = \"" requested_type "\";"
            print insert_indent "\t};"
            print insert_indent "};"
            if (requested_type == "HMBIRD_EXT" && existing_overlay == 0 &&
                insert_at == overlay_end[target_overlay])
                print ""
        }
        if (existing_overlay != 0 && i >= existing_hmbird_start &&
            i <= existing_hmbird_end)
            continue
        print lines[i]
    }
}
