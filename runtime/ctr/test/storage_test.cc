#include "storage.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <dirent.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

static bool Exists(const std::string& path) {
  struct stat info;
  return stat(path.c_str(), &info) == 0;
}
static int Entries(const std::string& path) {
  DIR* dir = opendir(path.c_str());
  assert(dir);
  int count = 0;
  for (dirent* entry; (entry = readdir(dir));)
    if (std::string(entry->d_name) != "." && std::string(entry->d_name) != "..") ++count;
  closedir(dir);
  return count;
}

int main() {
  // Directory.current starts in the folder of the application file.
  assert(ctr::AppFolder("sdmc:/3ds/hello.3dsx") == "sdmc:/3ds");
  assert(ctr::AppFolder("sdmc:/apps/demo/demo.3dsx") == "sdmc:/apps/demo");
  assert(ctr::AppFolder("sdmc:/hello.3dsx") == "sdmc:/");
  assert(ctr::AppFolder("3dslink:/hello.3dsx").empty());
  assert(ctr::AppFolder("").empty());
  assert(ctr::AppFolder(nullptr).empty());

  // The temporary directory and its parents are created, then emptied at
  // every start.
  char base[] = "/tmp/ctr-storage-XXXXXX";
  assert(mkdtemp(base));
  const std::string temp = std::string(base) + "/dartbrew/tmp";
  assert(ctr::ClearDirectory(temp));
  assert(Exists(temp) && Entries(temp) == 0);
  assert(mkdir((temp + "/nested").c_str(), 0777) == 0);
  FILE* file = fopen((temp + "/nested/file.txt").c_str(), "w");
  assert(file && fputs("x", file) >= 0 && fclose(file) == 0);
  file = fopen((temp + "/top.txt").c_str(), "w");
  assert(file && fclose(file) == 0);
  assert(ctr::ClearDirectory(temp));
  assert(Exists(temp) && Entries(temp) == 0);
  assert(rmdir(temp.c_str()) == 0);
  assert(rmdir((std::string(base) + "/dartbrew").c_str()) == 0);
  assert(rmdir(base) == 0);
}
