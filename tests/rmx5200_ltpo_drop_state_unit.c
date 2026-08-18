#include <assert.h>
#include <stdio.h>

#include "../src/rmx5200_ltpo_drop_state.h"

typedef struct {
    Rmx5200LtpoDropState drop;
    int current_hz;
    int ceiling_hz;
    int pending_hz;
    int superseded_hz;
    int touch_down;
    int recovery_submitted;
} Controller;

static void init_controller(Controller *controller, int ceiling_hz) {
    rmx5200_drop_state_init(&controller->drop);
    controller->current_hz = ceiling_hz;
    controller->ceiling_hz = ceiling_hz;
    controller->pending_hz = 0;
    controller->superseded_hz = 0;
    controller->touch_down = 0;
    controller->recovery_submitted = 0;
}

static void submit_drop(Controller *controller, int target_hz) {
    assert(!controller->touch_down);
    assert(controller->pending_hz == 0);
    controller->pending_hz = target_hz;
    rmx5200_drop_begin(&controller->drop);
}

static void touch_down(Controller *controller) {
    controller->touch_down = 1;
    if (rmx5200_drop_supersede_for_activity(&controller->drop)) {
        controller->superseded_hz = controller->pending_hz;
        controller->pending_hz = 0;
    }
    controller->current_hz = controller->ceiling_hz;
}

static void receive_drop(Controller *controller, int physical_hz) {
    if (controller->pending_hz == physical_hz &&
            rmx5200_drop_receipt_is_owned(&controller->drop,
                                           controller->touch_down)) {
        controller->current_hz = physical_hz;
        controller->pending_hz = 0;
        rmx5200_drop_clear_pending(&controller->drop);
        return;
    }
    if (controller->superseded_hz == physical_hz) {
        controller->superseded_hz = 0;
        controller->recovery_submitted++;
        rmx5200_drop_clear_superseded(&controller->drop);
    }
}

static void check_late_receipt(int ceiling_hz, int stale_hz) {
    Controller controller;

    init_controller(&controller, ceiling_hz);
    submit_drop(&controller, stale_hz);
    touch_down(&controller);
    assert(controller.current_hz == ceiling_hz);
    assert(controller.pending_hz == 0);
    assert(!rmx5200_drop_receipt_is_owned(&controller.drop, 1));

    receive_drop(&controller, stale_hz);
    assert(controller.current_hz == ceiling_hz);
    assert(controller.recovery_submitted == 1);

    receive_drop(&controller, stale_hz);
    assert(controller.current_hz == ceiling_hz);
    assert(controller.recovery_submitted == 1);
}

int main(void) {
    static const int ceilings[] = { 120, 123, 144, 150, 165, 180 };
    static const int stale_drops[] = { 1, 10, 30, 60 };

    for (unsigned int i = 0;
            i < sizeof(ceilings) / sizeof(ceilings[0]); i++) {
        for (unsigned int j = 0;
                j < sizeof(stale_drops) / sizeof(stale_drops[0]); j++) {
            check_late_receipt(ceilings[i], stale_drops[j]);
        }
    }

    Controller normal;
    init_controller(&normal, 144);
    submit_drop(&normal, 120);
    receive_drop(&normal, 120);
    assert(normal.current_hz == 120);
    assert(normal.pending_hz == 0);

    puts("PASS: superseded idle-drop receipts cannot steal LTPO ownership");
    return 0;
}
