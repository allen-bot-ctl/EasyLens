// Minimal compile-time stub for FocusText.swift's resolveFocus return type.
// Only used when building the CI selection reader; the runtime path never calls
// resolveFocus (LocalTranslation.swift owns the real FocusedTranslation).
struct FocusedTranslation {
    let chinese: String?
    let basis: String
}
