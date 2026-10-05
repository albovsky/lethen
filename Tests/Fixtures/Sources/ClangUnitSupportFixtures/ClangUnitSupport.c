#include "ClangUnitSupportFixtures.h"

int clangUnitSupportAnswer(void) {
    return 42;
}

// A string literal in C code is not a name Swift looks up at run time.
const char *clangUnitSupportName(void) {
    return "namedInClangLiteral";
}

// `NSClassFromString` loads any Swift class by its name, so this literal can name one.
const char *clangUnitSupportClassName(void) {
    return "FixtureClass240Loaded";
}
