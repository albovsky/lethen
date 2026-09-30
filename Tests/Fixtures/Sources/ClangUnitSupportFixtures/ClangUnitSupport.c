#include "ClangUnitSupportFixtures.h"

int clangUnitSupportAnswer(void) {
    return 42;
}

// A string literal in C code is not a name Swift looks up at run time.
const char *clangUnitSupportName(void) {
    return "namedInClangLiteral";
}
