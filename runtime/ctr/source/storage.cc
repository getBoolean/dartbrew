#include "storage.h"
#include <cerrno>
#include <cstring>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>
#include <vector>
namespace ctr {
std::string AppFolder(const char* argv0) {
  static const char kSdmc[] = "sdmc:/";
  if (!argv0 || strncmp(argv0, kSdmc, sizeof(kSdmc) - 1)) return {};
  const char* slash = strrchr(argv0, '/');
  // The SD card root keeps its separator.
  const size_t length = slash - argv0 == sizeof(kSdmc) - 2 ? sizeof(kSdmc) - 1 : slash - argv0;
  return std::string(argv0, length);
}
// Removes everything inside the directory |path|. Entries are read before
// any is removed, so removal cannot disturb the directory iteration.
static bool Empty(const std::string& path) {
  DIR* dir = opendir(path.c_str());
  if (!dir) return false;
  std::vector<std::pair<std::string, bool>> entries;
  for (dirent* entry; (entry = readdir(dir));) {
    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
    std::string child = path + "/" + entry->d_name;
    struct stat info;
    entries.emplace_back(child, stat(child.c_str(), &info) == 0 && S_ISDIR(info.st_mode));
  }
  closedir(dir);
  bool ok = true;
  for (const auto& [child, directory] : entries)
    ok = (directory ? Empty(child) && rmdir(child.c_str()) == 0 : unlink(child.c_str()) == 0) && ok;
  return ok;
}
bool ClearDirectory(const std::string& path) {
  // Create the parents first: everything up to each separator after a device
  // prefix's root.
  const size_t root = path.find(":/") == std::string::npos ? 1 : path.find(":/") + 2;
  for (size_t at = path.find('/', root); at != std::string::npos; at = path.find('/', at + 1))
    mkdir(path.substr(0, at).c_str(), 0777);
  if (mkdir(path.c_str(), 0777) != 0 && errno != EEXIST) {
    struct stat info;
    if (stat(path.c_str(), &info) != 0 || !S_ISDIR(info.st_mode)) return false;
  }
  return Empty(path);
}
}
