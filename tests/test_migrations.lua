-- tests/test_migrations.lua  —  schema migration framework.

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local helpers = require("tests.helpers")
helpers.install_ngx_stub()

local migrations = require("agent_mux.session.migrations")

describe("session.migrations.apply", function()
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

helpers.uninstall_ngx_stub()
