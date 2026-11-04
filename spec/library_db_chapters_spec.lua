-- putChapters idempotence: the catalog self-heal on the quick-menu path may
-- hand the same snapshot to putChapters repeatedly (once per consumer call,
-- with a fresh book table every time). Rewriting every chapter row (DELETE +
-- full INSERT + WAL fsync) is a UI-thread stall on e-ink devices, so a
-- snapshot equal to the stored catalog must be a no-op, while any real change
-- (row count, order, uid, payload) still rewrites.
-- Run from the repo root with:
--   luajit spec/library_db_chapters_spec.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

-- Real SQLite FFI bridge (same codec pattern as
-- spec/helpers/annotation_test_store.lua) in place of lua-ljsqlite3, which is
-- not part of the test environment.
local helper = require("spec.helpers.annotation_test_store")
package.preload["lua-ljsqlite3/init"] = function()
    return { open = function(path) return helper.connect(path) end }
end

local LibraryDB = require("weread.lib.library_db")

local settings = {
    data_dir = "/tmp",
    get = function(_self, key, default)
        if key == "account" then return { user_vid = "chapters-it-spec" } end
        return default
    end,
}
local db = LibraryDB:new(settings)
local path = db:databasePath()
os.remove(path); os.remove(path .. "-wal"); os.remove(path .. "-shm")

local checks, failures = 0, 0
local function expect(value, label)
    checks = checks + 1
    if not value then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

local function make_chapters(n, tag)
    local chapters = {}
    for i = 1, n do
        chapters[i] = { chapterUid = tostring(1000 + i),
            title = "Chapter " .. i .. (tag or "") }
    end
    return chapters
end

local function stored_rows(book_id)
    local conn = db:open()
    expect(conn ~= nil, "database opens for inspection")
    local stmt = conn:prepare(
        "SELECT chapter_uid, payload FROM chapters WHERE book_id=? ORDER BY position")
    stmt:reset():bind(tostring(book_id))
    local rows = {}
    local row = stmt:step()
    while row do
        rows[#rows + 1] = { uid = row[1], payload = row[2] }
        row = stmt:step()
    end
    stmt:close()
    conn:close()
    return rows
end

local function snapshot(book_id)
    local out = {}
    for _, r in ipairs(stored_rows(book_id)) do
        out[#out + 1] = r.uid .. "|" .. r.payload
    end
    return table.concat(out, "\n")
end

-- Full-rewrite detector: puts an SQLite trigger landmine into the write path.
-- putChapters rewrites by DELETE+INSERT, so an INSERT trigger that aborts
-- fires exactly when the rewrite happens; a true no-op skips it.
local function arm_rewrite_trap(book_id)
    local conn = db:open()
    conn:exec("CREATE TABLE IF NOT EXISTS library_rewrite_probe (hits INTEGER NOT NULL DEFAULT 0)")
    -- The trigger UPDATEs this row; UPDATE without a row is a no-op, so seed it.
    conn:exec("INSERT INTO library_rewrite_probe (hits) SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM library_rewrite_probe)")
    pcall(function() conn:exec("DROP TRIGGER IF EXISTS rewrite_trap") end)
    conn:exec(string.format([[
        CREATE TRIGGER rewrite_trap AFTER INSERT ON chapters
        WHEN NEW.book_id='%s'
        BEGIN
            UPDATE library_rewrite_probe SET hits = hits + 1;
        END
    ]], tostring(book_id)))
    conn:close()
end

local function disarm_rewrite_trap()
    local conn = db:open()
    pcall(function() conn:exec("DROP TRIGGER IF EXISTS rewrite_trap") end)
    pcall(function() conn:exec("DELETE FROM library_rewrite_probe") end)
    conn:close()
end

local function rewrite_hits()
    local conn = db:open()
    local stmt = conn:prepare("SELECT hits FROM library_rewrite_probe")
    local row = stmt:step()
    stmt:close()
    conn:close()
    return row and tonumber(row[1]) or 0
end

-- 1) First write stores the catalog.
local chapters = make_chapters(3)
expect(db:putChapters("b1", chapters), "first putChapters stores the catalog")
local first_snapshot = snapshot("b1")
expect(#stored_rows("b1") == 3, "first write created three rows")

-- 2) Same snapshot through a fresh LibraryDB instance and fresh chapter
--    tables (what every settings:get("books") call produces) must not change
--    any stored byte. The trigger trap counts INSERTs, so a silent rewrite
--    (same payload result) cannot fool the assertion.
local trap = { was_armed = false }
arm_rewrite_trap("b1")
expect(rewrite_hits() == 0, "rewrite trap armed at zero")
db = LibraryDB:new(settings)
local fresh_chapters = make_chapters(3)
expect(db:putChapters("b1", fresh_chapters), "idempotent putChapters returns true")
expect(snapshot("b1") == first_snapshot,
    "same snapshot left stored rows byte-identical")
expect(#stored_rows("b1") == 3, "idempotent write kept the row count")
expect(rewrite_hits() == 0, "idempotent write skipped the row rewrite")

-- 3) A real change (different payload) still rewrites — and trips the trap.
db = LibraryDB:new(settings)
local changed = make_chapters(3, " v2")
expect(db:putChapters("b1", changed), "changed catalog write succeeds")
expect(snapshot("b1") ~= first_snapshot, "changed payload was rewritten")
expect(#stored_rows("b1") == 3, "changed write kept the row count")
expect(rewrite_hits() == 3, "changed write performed the full row rewrite")
disarm_rewrite_trap()

-- 4) Row count growth and shrink rewrite.
expect(db:putChapters("b1", make_chapters(5)), "growing catalog write succeeds")
expect(#stored_rows("b1") == 5, "growth rewrote the row count")
expect(db:putChapters("b1", make_chapters(2)), "shrinking catalog write succeeds")
expect(#stored_rows("b1") == 2, "shrink rewrote the row count")

-- 5) Reordering rewrites (stored positions must follow the new snapshot).
local base = make_chapters(3)
local reordered = { base[2], base[1], base[3] }
expect(db:putChapters("b1", reordered), "reordered catalog write succeeds")
local reorder_rows = stored_rows("b1")
expect(reorder_rows[1].uid == "1002" and reorder_rows[2].uid == "1001",
    "reorder updated stored positions")

-- 6) Reordered snapshot repeated: idempotent (order included in comparison).
db = LibraryDB:new(settings)
expect(db:putChapters("b1", reordered), "repeated reordered write returns true")
local repeat_rows = stored_rows("b1")
expect(repeat_rows[1].uid == "1002" and repeat_rows[2].uid == "1001",
    "repeated reordered write kept stored positions")

-- 7) Chapter falling back to a numeric uid (no chapterUid/chapterId) still
--    compares and rewrites consistently.
local numeric = { { title = "no uid one" }, { title = "no uid two" } }
expect(db:putChapters("b3", numeric), "numeric-uid catalog write succeeds")
db = LibraryDB:new(settings)
expect(db:putChapters("b3", { { title = "no uid one" }, { title = "no uid two" } }),
    "numeric-uid idempotent write returns true")
expect(#stored_rows("b3") == 2, "numeric-uid rows stable")

helper.cleanup()
for _, suffix in ipairs({ "", "-wal", "-shm" }) do
    os.remove(path .. suffix)
end

print(string.format("library_db_chapters_spec: %d checks, %d failure(s)",
    checks, failures))
os.exit(failures == 0 and 0 or 1)
