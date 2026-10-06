#pragma once
#define _GNU_SOURCE 1
#include <sqlite3.h>
#include <gumbo.h>
#include <zlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <spawn.h>
#include <sys/wait.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
