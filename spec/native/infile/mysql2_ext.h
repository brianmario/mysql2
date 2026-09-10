/* Minimal declarations for testing the real LOCAL INFILE callbacks in isolation. */
#ifndef MYSQL2_INFILE_TEST_EXT_H
#define MYSQL2_INFILE_TEST_EXT_H
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
typedef struct { int unused; } MYSQL;
typedef struct { int unused; } mysql_client_wrapper;
#define CR_UNKNOWN_ERROR 2000
#define CR_OUT_OF_MEMORY 2008
static void mysql_set_local_infile_handler(MYSQL *mysql,
    int (*init)(void **, const char *, void *),
    int (*read_cb)(void *, char *, unsigned int), void (*end)(void *),
    int (*error)(void *, char *, unsigned int), void *userdata) {
  (void)mysql; (void)init; (void)read_cb; (void)end; (void)error; (void)userdata;
}
#endif
