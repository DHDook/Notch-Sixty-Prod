// try/catch for off-thread construction that may allocate (C interface Create functions), usable in a translation unit
// that is built with exceptions off. CMake builds the two ANC files with exceptions on (-fexceptions, /EHsc); clang-cl
// through the Visual Studio generator keeps the target-wide /EHs-c- instead, so there the catch arm is compiled out and
// an allocation failure terminates, as everywhere else in the core.
#pragma once

#if defined(__cpp_exceptions)
#define N60_TRY try
#define N60_CATCH_ALL catch (...)
#else
#define N60_TRY if (true)
#define N60_CATCH_ALL else
#endif
