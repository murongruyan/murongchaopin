#ifndef RMX5200_LTPO_DROP_STATE_H
#define RMX5200_LTPO_DROP_STATE_H

typedef struct {
    unsigned long long transition_generation;
    unsigned long long pending_drop_generation;
    unsigned long long superseded_drop_generation;
} Rmx5200LtpoDropState;

static inline void rmx5200_drop_state_init(Rmx5200LtpoDropState *state) {
    state->transition_generation = 1;
    state->pending_drop_generation = 0;
    state->superseded_drop_generation = 0;
}

static inline unsigned long long rmx5200_drop_begin(
        Rmx5200LtpoDropState *state) {
    state->pending_drop_generation = state->transition_generation;
    return state->pending_drop_generation;
}

static inline void rmx5200_drop_clear_pending(
        Rmx5200LtpoDropState *state) {
    state->pending_drop_generation = 0;
}

static inline int rmx5200_drop_supersede_for_activity(
        Rmx5200LtpoDropState *state) {
    int had_pending = state->pending_drop_generation != 0;

    if (had_pending)
        state->superseded_drop_generation =
                state->pending_drop_generation;
    state->pending_drop_generation = 0;
    state->transition_generation++;
    if (state->transition_generation == 0)
        state->transition_generation = 1;
    return had_pending;
}

static inline int rmx5200_drop_receipt_is_owned(
        const Rmx5200LtpoDropState *state, int touch_down) {
    return !touch_down && state->pending_drop_generation != 0 &&
            state->pending_drop_generation == state->transition_generation;
}

static inline void rmx5200_drop_clear_superseded(
        Rmx5200LtpoDropState *state) {
    state->superseded_drop_generation = 0;
}

#endif
