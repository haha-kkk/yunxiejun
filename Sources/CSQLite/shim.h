#include <sqlite3.h>

// 让 SQLite 在返回前复制 Swift 临时字符串，不持有已失效的指针。
static inline int typeless_bind_text(sqlite3_stmt *statement, int index, const char *value) {
    return sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT);
}
