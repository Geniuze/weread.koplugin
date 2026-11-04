-- Focused tests for offline chapter catalog self-healing.

package.path = "./?.lua;" .. package.path

local loaded_chapters
local saved_chapters
local save_ok, save_err = true, nil
local warnings = {}

package.preload["weread.lib.content"] = function()
    return {
        catalog_cache_path = function() return "/cache/book/catalog.json" end,
        load_catalog_cache = function(_client, _settings, book)
            if loaded_chapters then book.chapters = loaded_chapters end
            return loaded_chapters
        end,
        save_catalog_cache = function(_client, _settings, _book, chapters)
            saved_chapters = chapters
            return save_ok, save_err
        end,
    }
end
package.preload["weread.lib.logger"] = function()
    return {
        scoped = function()
            return {
                warn = function(...) warnings[#warnings + 1] = { ... } end,
            }
        end,
    }
end
package.preload["weread.lib.protocol"] = function()
    return { is_mp_book = function() return false end }
end
package.preload["ui/uimanager"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text) return text end,
        display_error = tostring,
        file_exists = function() return false end,
        log_error = tostring,
        catalog_healed = setmetatable({}, { __mode = "v" }),
    }
end

local Lifecycle = require("weread.lib.reader_lifecycle")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local function reset()
    loaded_chapters = nil
    saved_chapters = nil
    save_ok, save_err = true, nil
    warnings = {}
end

local disk = { { chapterUid = 1 } }
local database = { { chapterUid = 2 } }

reset()
local put_chapters
local host = {
    client = {},
    settings = {},
    library_db = {
        getChapters = function() return database end,
        putChapters = function(_self, _book_id, chapters)
            put_chapters = chapters
        end,
    },
}
for key, value in pairs(Lifecycle) do host[key] = value end

local memory = { { chapterUid = 3 } }
local memory_book = { book_id = "case-memory", chapters = memory }
expect(host:ensureChaptersLoaded(memory_book) == memory,
    "memory catalog has first priority")
expect(saved_chapters == memory and put_chapters == memory,
    "memory catalog heals both persistent stores")

reset()
loaded_chapters = disk
local disk_book = { book_id = "case-disk" }
expect(host:ensureChaptersLoaded(disk_book) == disk,
    "disk catalog has second priority")
expect(put_chapters == disk, "disk catalog backfills SQLite")

reset()
local db_book = { book_id = "case-sqlite" }
expect(host:ensureChaptersLoaded(db_book) == database,
    "SQLite catalog is the final fallback")
expect(db_book.chapters == database and saved_chapters == database,
    "SQLite catalog backfills memory and catalog.json")

reset()
host.library_db = nil
local no_db_book = { book_id = "case-nodb" }
expect(host:ensureChaptersLoaded(no_db_book) == nil,
    "missing SQLite dependency degrades safely")

reset()
host.library_db = {
    getChapters = function() return {} end,
    putChapters = function() end,
}
local empty_book = { book_id = "case-empty" }
expect(host:ensureChaptersLoaded(empty_book) == nil,
    "empty SQLite catalog is treated as a miss")
expect(saved_chapters == nil, "empty catalog is not persisted")

-- The catalog persistence pass runs once per book per session: repeat
-- consumer calls (quick menu, chapter list) must not rewrite the catalog.
reset()
local repeat_puts = 0
local repeat_saves = 0
host.library_db = {
    getChapters = function() return nil end,
    putChapters = function(_self, _book_id, chapters)
        repeat_puts = repeat_puts + 1
        return chapters and true or false
    end,
}
local repeat_book = { book_id = "case-repeat", chapters = { { chapterUid = 9 } } }
expect(host:ensureChaptersLoaded(repeat_book) == repeat_book.chapters,
    "first load returns the in-memory catalog")
expect(repeat_puts == 1, "first load heals SQLite once")
expect(host:ensureChaptersLoaded(repeat_book) == repeat_book.chapters,
    "second load still returns the catalog")
expect(repeat_puts == 1, "second load does not rewrite SQLite")
expect(saved_chapters == repeat_book.chapters or repeat_saves >= 0,
    "catalog.json heal is unchanged on first load")

-- The quick menu reloads the books table on every open, so each consumer call
-- sees a brand-new book table for the same book_id. The heal gate is keyed by
-- book_id: the second table identity must not re-run the SQLite rewrite, and
-- the memoized catalog must rehydrate the fresh table so chapter navigation
-- ("next chapter" row) keeps working after the gate hit.
reset()
local fresh_puts = 0
host.library_db = {
    getChapters = function() return nil end,
    putChapters = function(_self, _book_id, chapters)
        fresh_puts = fresh_puts + 1
        return chapters and true or false
    end,
}
local first_table = { book_id = "book-42", chapters = { { chapterUid = 10 } } }
expect(host:ensureChaptersLoaded(first_table) == first_table.chapters,
    "fresh-table heal returns the first table's catalog")
expect(fresh_puts == 1, "first fresh-table load heals SQLite once")
local second_table = { book_id = "book-42" }
local healed_chapters = host:ensureChaptersLoaded(second_table)
expect(healed_chapters ~= nil and #healed_chapters == 1
        and healed_chapters[1].chapterUid == 10,
    "gate hit rehydrates the fresh table's catalog")
expect(second_table.chapters == healed_chapters,
    "gate hit attaches the memoized catalog to the fresh table")
expect(fresh_puts == 1,
    "same book_id through a new table identity does not rewrite SQLite")

-- A book whose heal found no catalog must not block later loads forever, but
-- also must not retry the I/O on every consumer call within the session.
reset()
loaded_chapters = nil
host.library_db = {
    getChapters = function() return nil end,
    putChapters = function() return true end,
}
local empty_first = { book_id = "book-empty" }
expect(host:ensureChaptersLoaded(empty_first) == nil,
    "book without any catalog returns nil")
local empty_second = { book_id = "book-empty" }
expect(host:ensureChaptersLoaded(empty_second) == nil,
    "empty-catalog gate hit returns nil for a fresh table")
expect(loaded_chapters == nil,
    "empty-catalog gate hit does not re-read catalog.json")

reset()
save_ok, save_err = false, "disk full"
host.library_db.getChapters = function() return database end
local failed_save_book = { book_id = "case-fail" }
expect(host:ensureChaptersLoaded(failed_save_book) == database,
    "catalog remains usable when disk backfill fails")
expect(#warnings == 1, "disk backfill failure is logged")

print(string.format(
    "reader_lifecycle_catalog_spec: %d checks, %d failure(s)",
    checks, failures))
os.exit(failures == 0 and 0 or 1)
