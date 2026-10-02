// Domine for Linux: pure logic checks run by `domine --self-test`.
#ifndef DOMINE_UI_SELFTEST_H
#define DOMINE_UI_SELFTEST_H

/// Returns 0 when every check passes, 1 otherwise (failures on stderr).
int dl_self_test(void);

#endif
