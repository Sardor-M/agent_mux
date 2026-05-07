-- tests/test_migrations.lua  —  schema migration framework, plus
-- coverage of the store.load → migrations.apply wiring (where pcall's
-- return values were previously misread).

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local helpers = require("tests.helpers")
helpers.install_ngx_stub()

local cjson      = require("cjson.safe")
local migrations = require("agent_mux.session.migrations")
local redis      = require("agent_mux.redis_client")
local store      = require("agent_mux.session.store")

describe("session.migrations.apply", function()
    before_each(function() helpers.install_ngx_stub() end)
    after_each(function() migrations._set_for_test({}) end)

    it("is a no-op when doc is already at target", function()
        local doc, applied = migrations.apply({ schema_version = 1 }, 1)
        assert.equals(0, applied)
        assert.equals(1, doc.schema_version)
    end)

    it("applies a single 1→2 migration", function()
        migrations._set_for_test({
            { from = 1, to = 2, migrate = function(d) d.added = true; return d end },
        })
        local doc, applied = migrations.apply({ schema_version = 1 }, 2)
        assert.equals(1, applied)
        assert.equals(2, doc.schema_version)
        assert.is_true(doc.added)
    end)

    it("applies a chain of migrations in order", function()
        migrations._set_for_test({
            { from = 1, to = 2, migrate = function(d) d.step1 = true; return d end },
            { from = 2, to = 3, migrate = function(d) d.step2 = true; return d end },
        })
        local doc, applied = migrations.apply({ schema_version = 1 }, 3)
        assert.equals(2, applied)
        assert.equals(3, doc.schema_version)
        assert.is_true(doc.step1)
        assert.is_true(doc.step2)
    end)

    it("raises when no migration path exists", function()
        migrations._set_for_test({})  -- no migrations registered
        assert.has_error(function()
            migrations.apply({ schema_version = 1 }, 2)
        end)
    end)
end)

-- Regression: a previous version of store.load() destructured pcall's
-- returns wrong (`local migrated, applied = pcall(...)`), which assigned
-- the boolean ok flag to `doc` after success. This test loads a doc with
-- an old schema_version and asserts that fields survive the round trip.
describe("session.store.load through migration path", function()
    local original_connect, original_release = redis.connect, redis.release

    before_each(function() helpers.install_ngx_stub() end)
    after_each(function()
        migrations._set_for_test({})
        redis.connect = original_connect
        redis.release = original_release
    end)

    it("returns a session with intact fields after migrating an older doc", function()
        -- Pretend the on-disk doc is at schema_version = 0 so the live
        -- SCHEMA_VERSION = 1 in store.lua triggers exactly one migration.
        local stored = {
            id             = "sess_old",
            schema_version = 0,
            model          = "claude-opus-4-7",
            messages       = { { role = "user", content = "hi" } },
            tools          = {},
            tool_policy    = { mode = "allow_all" },
            usage          = { input_tokens = 0, output_tokens = 0 },
            budget         = { max_tokens = 1, wall_clock_ms = 1 },
            status         = "running",
            created_at     = 1, updated_at = 1,
        }

        migrations._set_for_test({
            {
                from = 0, to = 1,
                migrate = function(d) d.migrated_marker = true; return d end,
            },
        })

        -- Stub a connection object that satisfies just store.load + flush.
        local fake_conn = {
            get = function(_, _) return cjson.encode(stored) end,
            set = function(_, _, _, _, _) return true end,
        }
        redis.connect = function() return fake_conn end
        redis.release = function() end

        local s, err = store.load("sess_old")
        assert.is_nil(err)
        assert.is_table(s)
        assert.equals("sess_old",        s.id)
        assert.equals("claude-opus-4-7", s.model)
        assert.equals(1,                 s.schema_version)
        assert.is_true(s.migrated_marker)
        assert.equals("running",         s.status)
        assert.equals("hi",              s.messages[1].content)
    end)
end)
