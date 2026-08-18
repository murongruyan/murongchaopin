#include <assert.h>
#include <stdio.h>

typedef struct {
    int cached_hz;
    int pending_ceiling_hz;
    int verified_ceiling_hz;
    int descent_allowed;
    int requested_hz[32];
    int request_count;
} Controller;

static int native_anchor_for_ceiling(int ceiling_hz) {
    return ceiling_hz >= 144 ? 144 : 120;
}

static void adopt_ko_preboost(Controller *controller, int ceiling_hz) {
    assert(ceiling_hz >= 120);
    int anchor_hz = native_anchor_for_ceiling(ceiling_hz);

    controller->cached_hz = anchor_hz;
    controller->pending_ceiling_hz = ceiling_hz;
    controller->descent_allowed = 0;
    controller->requested_hz[controller->request_count++] = anchor_hz;
}

static void receive_physical_commit(Controller *controller, int refresh_hz) {
    if (controller->pending_ceiling_hz == refresh_hz) {
        controller->cached_hz = refresh_hz;
        controller->verified_ceiling_hz = refresh_hz;
        controller->pending_ceiling_hz = 0;
        controller->descent_allowed = 1;
    }
}

static void check_ceiling(int ceiling_hz) {
    Controller controller = { .cached_hz = 1 };

    adopt_ko_preboost(&controller, ceiling_hz);
    int anchor_hz = native_anchor_for_ceiling(ceiling_hz);

    assert(controller.cached_hz == anchor_hz);

    /* The KO's native 120/144Hz receipt is the adopted anchor, not a second
     * daemon request. In particular, a 144Hz ceiling never visits 120Hz. */
    receive_physical_commit(&controller, anchor_hz);
    if (ceiling_hz == anchor_hz) {
        assert(controller.cached_hz == anchor_hz);
        assert(controller.verified_ceiling_hz == anchor_hz);
        return;
    }
    assert(controller.cached_hz == anchor_hz);
    assert(controller.pending_ceiling_hz == ceiling_hz);
    assert(controller.descent_allowed == 0);

    receive_physical_commit(&controller, ceiling_hz);
    assert(controller.cached_hz == ceiling_hz);
    assert(controller.verified_ceiling_hz == ceiling_hz);
    assert(controller.descent_allowed == 1);

    /* A stale native-anchor notification cannot overwrite the ceiling. */
    receive_physical_commit(&controller, anchor_hz);
    assert(controller.cached_hz == ceiling_hz);
}

static void check_native_request_paths(void) {
    Controller native_120 = { .cached_hz = 1 };
    Controller custom_123 = { .cached_hz = 1 };
    Controller native_144 = { .cached_hz = 1 };
    Controller custom_165 = { .cached_hz = 1 };

    adopt_ko_preboost(&native_120, 120);
    adopt_ko_preboost(&custom_123, 123);
    adopt_ko_preboost(&native_144, 144);
    adopt_ko_preboost(&custom_165, 165);

    assert(native_120.request_count == 1);
    assert(native_120.requested_hz[0] == 120);
    assert(custom_123.request_count == 1);
    assert(custom_123.requested_hz[0] == 120);

    /* 144Hz is native: the physical rise must be 1->144, never 1->120->144. */
    assert(native_144.request_count == 1);
    assert(native_144.requested_hz[0] == 144);

    /* Higher custom ceilings start at native 144, then use the OC ladder. */
    assert(custom_165.request_count == 1);
    assert(custom_165.requested_hz[0] == 144);
}

int main(void) {
    check_native_request_paths();
    for (int ceiling_hz = 120; ceiling_hz <= 300; ceiling_hz++) {
        check_ceiling(ceiling_hz);
    }

    puts("PASS: native 144 rises directly and KO pre-boost cannot split daemon state");
    return 0;
}
