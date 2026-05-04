-- tests/test_stream_parser.lua  —  unit tests for upstream/stream.lua.
--
-- The parser is pure Lua (no ngx surface) so these tests run without an
-- nginx stub. They exercise the SSE corner cases that bite in the wild:
-- chunk boundaries mid-line, mid-event, and at the very end of the stream.

package.path = "lua/?.lua;lua/?/init.lua;" .. package.path

local Stream = require("agent_mux.upstream.stream")

describe("upstream.stream", function()
    it("parses one whole event in a single feed", function()
        local s = Stream.new()
        local events = s:feed("event: foo\ndata: hello\n\n")
        assert.equals(1, #events)
        assert.equals("foo", events[1].event)
        assert.equals("hello", events[1].data)
    end)

    it("handles event split across many chunks", function()
        local s = Stream.new()
        assert.equals(0, #s:feed("event: f"))
        assert.equals(0, #s:feed("oo\nda"))
        assert.equals(0, #s:feed("ta: hello"))
        local events = s:feed("\n\n")
        assert.equals(1, #events)
        assert.equals("foo", events[1].event)
        assert.equals("hello", events[1].data)
    end)

    it("yields multiple events from a single feed", function()
        local s = Stream.new()
        local events = s:feed(
            "event: a\ndata: 1\n\n" ..
            "event: b\ndata: 2\n\n"
        )
        assert.equals(2, #events)
        assert.equals("1", events[1].data)
        assert.equals("2", events[2].data)
    end)

    it("ignores comment lines (keepalive pings)", function()
        local s = Stream.new()
        local events = s:feed(": ping\nevent: x\ndata: y\n\n")
        assert.equals(1, #events)
        assert.equals("y", events[1].data)
    end)

    it("joins multi-line data with newlines", function()
        local s = Stream.new()
        local events = s:feed("data: line1\ndata: line2\n\n")
        assert.equals(1, #events)
        assert.equals("line1\nline2", events[1].data)
    end)

    it("tolerates CRLF line endings", function()
        local s = Stream.new()
        local events = s:feed("event: x\r\ndata: y\r\n\r\n")
        assert.equals(1, #events)
        assert.equals("x", events[1].event)
        assert.equals("y", events[1].data)
    end)

    it("strips a single leading space after `field:`", function()
        local s = Stream.new()
        local events = s:feed("data:no_space\ndata: with_space\n\n")
        assert.equals(1, #events)
        assert.equals("no_space\nwith_space", events[1].data)
    end)

    it("captures id field", function()
        local s = Stream.new()
        local events = s:feed("event: x\nid: 42\ndata: y\n\n")
        assert.equals("42", events[1].id)
    end)

    it("close() flushes any partial event", function()
        local s = Stream.new()
        local _ = s:feed("data: tail")  -- no terminator
        local closing = s:close()
        assert.equals(1, #closing)
        assert.equals("tail", closing[1].data)
    end)
end)
