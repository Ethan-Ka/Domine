/// Which speaker position plays the test tone. Raw values match
/// `domine_kernel_set_test_tone`.
enum TestTone: Int32, Sendable {
    case off = 0
    case left = 1
    case right = 2
}
