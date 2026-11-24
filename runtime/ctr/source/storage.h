#ifndef CTR_STORAGE_H_
#define CTR_STORAGE_H_
#include <string>
namespace ctr {
// The folder holding the application file named by argv[0], as newlib names
// it ("sdmc:/3ds/hello.3dsx" gives "sdmc:/3ds"). Empty when argv[0] is
// missing or does not name a file on the SD card (Azahar passes no argv).
std::string AppFolder(const char* argv0);
// Makes |path| an empty directory, creating it and its parents as needed.
// dart:io's Directory.systemTemp, cleared at every application start.
bool ClearDirectory(const std::string& path);
}
#endif
