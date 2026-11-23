// The dart:io path model on CTR (runtime/bin/path_ctr.cc).
#include "bin/path_ctr.h"
#include <cassert>
#include <cstring>
#include <string>

namespace {
std::string Native(const char* path) {
  char out[64];
  const size_t length = dart::bin::CtrNativePath(path, out, sizeof(out));
  assert(length < sizeof(out));
  assert(strlen(out) == length);
  return out;
}
std::string Dart(const char* path) {
  char copy[64];
  strcpy(copy, path);
  dart::bin::CtrDartPath(copy);
  return copy;
}
std::string Absolute(const char* cwd, const char* path) {
  char out[64];
  assert(dart::bin::CtrAbsolutePath(cwd, path, out, sizeof(out)));
  return out;
}
}  // namespace

int main() {
  // "/" is the SD card root; relative and device paths are left to newlib.
  assert(Native("/3ds/app") == "sdmc:/3ds/app");
  assert(Native("/") == "sdmc:/");
  assert(Native("data/x") == "data/x");
  assert(Native("romfs:/data") == "romfs:/data");
  assert(Native("sdmc:/3ds") == "sdmc:/3ds");
  char small[8];
  assert(dart::bin::CtrNativePath("/3ds/app", small, sizeof(small)) == 13);

  // Native and Dart paths reported to Dart code: sdmc: becomes "/".
  assert(Dart("sdmc:/3ds/") == "/3ds");
  assert(Dart("sdmc:/") == "/");
  assert(Dart("sdmc:") == "/");
  assert(Dart("/") == "/");
  assert(Dart("/a//") == "/a");
  assert(Dart("romfs:/") == "romfs:/");
  assert(Dart("romfs:/data/") == "romfs:/data");

  // Absolute paths: sdmc:/x and /x are the same entry.
  assert(Absolute("/3ds", "x") == "/3ds/x");
  assert(Absolute("/3ds", "sdmc:/3ds/x") == "/3ds/x");
  assert(Absolute("/3ds", "/3ds/./a/../x") == "/3ds/x");
  assert(Absolute("/3ds", "a//b/") == "/3ds/a/b");
  assert(Absolute("/3ds", "") == "/3ds");
  assert(Absolute("/3ds", ".") == "/3ds");
  assert(Absolute("/3ds", "..") == "/");
  assert(Absolute("/", "../..") == "/");
  assert(Absolute("/3ds", "sdmc:") == "/");
  assert(Absolute("/3ds", "romfs:/data/../a") == "romfs:/a");
  assert(Absolute("romfs:/", "a") == "romfs:/a");
  assert(Absolute("romfs:/data", "..") == "romfs:/");
  assert(Absolute("sdmc:/3ds/", "x") == "/3ds/x");
  char tiny[6];
  assert(!dart::bin::CtrAbsolutePath("/3ds", "a/b/c", tiny, sizeof(tiny)));
}
