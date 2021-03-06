describe("low level http 1 connection operations", function()
	local h1_connection = require "http.h1_connection"
	local cqueues = require "cqueues"
	local cs = require "cqueues.socket"
	local ce = require "cqueues.errno"
	it("cannot construct with invalid type", function()
		local s = cs.pair()
		assert.has.errors(function() h1_connection.new(s, nil, 1.1) end)
		assert.has.errors(function() h1_connection.new(s, "", 1.1) end)
		assert.has.errors(function() h1_connection.new(s, "invalid", 1.1) end)
	end)
	it("__tostring works", function()
		local h = h1_connection.new(cs.pair(), "client", 1.1)
		assert.same("http.h1_connection{", tostring(h):match("^.-%{"))
	end)
	local function new_pair(version)
		local s, c = cs.pair()
		s = h1_connection.new(s, "server", version)
		c = h1_connection.new(c, "client", version)
		return s, c
	end
	it(":take_socket works", function()
		local s = new_pair(1.1)
		local sock = s:take_socket()
		assert.same(debug.getmetatable((cs.pair())), debug.getmetatable(sock))
		-- 2nd time it should return nil
		assert.same(nil, s:take_socket())
	end)
	it(":localname and :peername work", function()
		do
			local s, c = new_pair(1.1)
			-- these are unnamed sockets; so 2nd return should be `nil`
			assert.same({cs.AF_UNIX, nil}, {s:localname()})
			assert.same({cs.AF_UNIX, nil}, {s:peername()})
			assert.same({cs.AF_UNIX, nil}, {c:localname()})
			assert.same({cs.AF_UNIX, nil}, {c:peername()})
		end
		do
			local s = new_pair(1.1)
			s:take_socket() -- take out socket (and discard)
			assert.same({nil}, {s:localname()})
			assert.same({nil}, {s:peername()})
		end
	end)
	it("errors should persist until cleared", function()
		local s, c = new_pair(1.1)
		assert.same({nil, ce.ETIMEDOUT}, {s:read_request_line(0)})
		c:close()
		assert.same({nil, ce.ETIMEDOUT}, {s:read_request_line()})
		s:clearerr()
		assert.same({nil, ce.EPIPE}, {s:read_request_line()})
		-- ensure it doesn't throw when socket is gone
		s:take_socket() -- take out socket (and discard)
		s:clearerr()
	end)
	it("request line should round trip", function()
		local function test(req_method, req_path, req_version)
			local s, c = new_pair(req_version)
			assert(c:write_request_line(req_method, req_path, req_version))
			assert(c:flush())
			local res_method, res_path, res_version = assert(s:read_request_line())
			assert.same(req_method, res_method)
			assert.same(req_path, res_path)
			assert.same(req_version, res_version)
		end
		test("GET", "/", 1.1)
		test("POST", "/foo", 1.0)
		test("OPTIONS", "*", 1.1)
	end)
	it(":write_request_line parameters should be validated", function()
		assert.has.errors(function() new_pair(1.1):write_request_line("", "/foo", 1.0) end)
		assert.has.errors(function() new_pair(1.1):write_request_line("GET", "", 1.0) end)
		assert.has.errors(function() new_pair(1.1):write_request_line("GET", "/", 0) end)
		assert.has.errors(function() new_pair(1.1):write_request_line("GET", "/", 2) end)
	end)
	it(":read_request_line should fail on invalid request", function()
		local function test(chunk)
			local s, c = new_pair(1.1)
			s = s:take_socket()
			assert(s:write(chunk, "\r\n"))
			assert(s:flush())
			assert.same({nil, "invalid request line"}, {c:read_request_line()})
		end
		test("invalid request line")
		test(" / HTTP/1.1")
		test("HTTP/1.1")
		test("GET HTTP/1.0")
		test("GET  HTTP/1.0")
		test("GET HTTP/1.0")
		test("GET HTTP/1.0")
		test("GET / HTP/1.1")
		test("GET / HTTP 1.1")
		test("GET / HTTP/1")
		test("GET / HTTP/2.0")
		test("GET / HTTP/1.1\nHeader: value") -- missing \r
	end)
	it("status line should round trip", function()
		local function test(req_version, req_status, req_reason)
			local s, c = new_pair(req_version)
			assert(s:write_status_line(req_version, req_status, req_reason))
			assert(s:flush())
			local res_version, res_status, res_reason = assert(c:read_status_line())
			assert.same(req_version, res_version)
			assert.same(req_status, res_status)
			assert.same(req_reason, res_reason)
		end
		test(1.1, "200", "OK")
		test(1.0, "404", "Not Found")
		test(1.1, "200", "")
		test(1.1, "999", "weird\1\127and wonderful\4bytes")
	end)
	it(":write_status_line parameters should be validated", function()
		assert.has.errors(function() new_pair(1.1):write_status_line(nil, "200", "OK") end)
		assert.has.errors(function() new_pair(1.1):write_status_line(0, "200", "OK") end)
		assert.has.errors(function() new_pair(1.1):write_status_line(2, "200", "OK") end)
		assert.has.errors(function() new_pair(1.1):write_status_line(math.huge, "200", "OK") end)
		assert.has.errors(function() new_pair(1.1):write_status_line("not a number", "200", "OK") end)
		assert.has.errors(function() new_pair(1.1):write_status_line(1.1, "", "OK") end)
		assert.has.errors(function() new_pair(1.1):write_status_line(1.1, "1000", "OK") end)
		assert.has.errors(function() new_pair(1.1):write_status_line(1.1, 200, "OK") end)
		assert.has.errors(function() new_pair(1.1):write_status_line(1.1, "200", "new lines\r\n") end)
	end)
	it(":read_status_line should throw on invalid status line", function()
		local function test(chunk)
			local s, c = new_pair(1.1)
			s = s:take_socket()
			assert(s:write(chunk, "\r\n"))
			assert(s:flush())
			assert.same({nil, "invalid status line"}, {c:read_status_line()})
		end
		test("invalid status line")
		test("HTTP/0 200 OK")
		test("HTTP/0.0 200 OK")
		test("HTTP/2.0 200 OK")
		test("HTTP/1 200 OK")
		test("HTTP/.1 200 OK")
		test("HTP/1.1 200 OK")
		test("1.1 200 OK")
		test(" 200 OK")
		test("200 OK")
		test("HTTP/1.1 0 OK")
		test("HTTP/1.1 1000 OK")
		test("HTTP/1.1  OK")
		test("HTTP/1.1 OK")
		test("HTTP/1.1 200")
		test("HTTP/1.1 200 OK\nHeader: value") -- missing \r
	end)
	it(":read_status_line should return EPIPE on EOF", function()
		local s, c = new_pair(1.1)
		s:close()
		assert.same({nil, ce.EPIPE}, {c:read_status_line()})
	end)
	it("headers should round trip", function()
		local function test(input)
			local s, c = new_pair(1.1)

			assert(c:write_request_line("GET", "/", 1.1))
			for _, t in ipairs(input) do
				assert(c:write_header(t[1], t[2]))
			end
			assert(c:write_headers_done())

			assert(s:read_request_line())
			for _, t in ipairs(input) do
				local k, v = assert(s:read_header())
				assert.same(t[1], k)
				assert.same(t[2], v)
			end
			assert(s:read_headers_done())
		end
		test{}
		test{
			{"foo", "bar"};
		}
		test{
			{"Host", "example.com"};
			{"User-Agent", "some user/agent"};
			{"Accept", "*/*"};
		}
	end)
	it(":read_header works in exotic conditions", function()
		do -- continuation
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("foo: bar\r\n qux\r\n\r\n", "bn"))
			c:close()
			assert.same({"foo", "bar qux"}, {s:read_header()})
		end
		do -- not a continuation, but only partial next header
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("foo: bar\r\npartial", "bn"))
			c:close()
			assert.same({"foo", "bar"}, {s:read_header()})
		end
		do -- not a continuation as gets a single byte of EOH
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("foo: bar\r\n\r", "bn"))
			c:close()
			assert.same({"foo", "bar"}, {s:read_header()})
		end
		do -- trickle
			local s, c = new_pair(1.1)
			c = c:take_socket()
			local cq = cqueues.new();
			cq:wrap(function()
				for char in ("foo: bar\r\n\r\n"):gmatch(".") do
					assert(c:xwrite(char, "bn"))
					cqueues.sleep(0.01)
				end
			end)
			cq:wrap(function()
				assert.same({"foo", "bar"}, {s:read_header()})
			end)
			assert(cq:loop())
		end
	end)
	it(":read_header should handle failure conditions", function()
		do -- no data
			local s, c = new_pair(1.1)
			c:close()
			assert.same({nil, ce.EPIPE}, {s:read_header()})
		end
		do -- sudden connection close
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("foo", "bn"))
			c:close()
			assert.same({nil, ce.EPIPE}, {s:read_header()})
		end
		do -- closed after new line
			-- unknown if this it was going to be a header continuation or not
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("foo: bar\r\n", "bn"))
			c:close()
			assert.same({nil, ce.EPIPE}, {s:read_header()})
		end
		do -- timeout
			local s, c = new_pair(1.1)
			assert.same({nil, ce.ETIMEDOUT}, {s:read_header(0.01)})
			c:close()
		end
		do -- connection reset
			local s, c = new_pair(1.1)
			assert(s:write_body_plain("something that flushes"))
			c:close()
			assert.same({nil, "read: Connection reset by peer", ce.ECONNRESET}, {s:read_header()})
		end
		do -- no field name
			local s, c = new_pair(1.1)
			assert(c:take_socket():xwrite(": fs\r\n\r\n", "bn"))
			assert.same({nil, "invalid header"}, {s:read_header()})
		end
		do -- no colon
			local s, c = new_pair(1.1)
			assert(c:take_socket():xwrite("foo bar\r\n\r\n", "bn"))
			assert.same({nil, "invalid header"}, {s:read_header()})
		end
	end)
	it(":read_headers_done should handle failure conditions", function()
		do -- no data
			local s, c = new_pair(1.1)
			c:close()
			assert.same({nil, ce.EPIPE}, {s:read_headers_done()})
		end
		do -- sudden connection close
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("\r", "bn"))
			c:close()
			assert.same({nil, ce.EPIPE}, {s:read_headers_done()})
		end
		do -- timeout
			local s, c = new_pair(1.1)
			assert.same({nil, ce.ETIMEDOUT}, {s:read_headers_done(0.01)})
			c:close()
		end
		do -- connection reset
			local s, c = new_pair(1.1)
			assert(s:write_body_plain("something that flushes"))
			c:close()
			assert.same({nil, "read: Connection reset by peer", ce.ECONNRESET}, {s:read_headers_done()})
		end
		do -- wrong byte
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("\0", "bn"))
			c:close()
			assert.same({nil, "invalid header: expected CRLF"}, {s:read_headers_done()})
		end
		do -- wrong bytes
			local s, c = new_pair(1.1)
			c = c:take_socket()
			assert(c:xwrite("hi", "bn"))
			c:close()
			assert.same({nil, "invalid header: expected CRLF"}, {s:read_headers_done()})
		end
	end)
	it(":write_header accepts odd fields", function()
		local s, c = new_pair(1.1)
		assert(s:write_header("foo", "bar"))
		assert(s:write_header("foo", " bar"))
		assert(s:write_header("foo", "bar "))
		assert(s:write_header("foo", "bar: stuff"))
		assert(s:write_header("foo", "bar, stuff"))
		assert(s:write_header("foo", "bar\n continuation"))
		assert(s:write_header("foo", "bar\r\n continuation"))
		assert(s:write_header("foo", "bar\r\n continuation: with colon"))
		c:close()
	end)
	it(":write_header rejects invalid headers", function()
		local s = new_pair(1.1)
		assert.has.errors(function() s:write_header() end)
		-- odd field names
		assert.has.errors(function() s:write_header(nil, "bar") end)
		assert.has.errors(function() s:write_header(":", "bar") end)
		assert.has.errors(function() s:write_header("\n", "bar") end)
		assert.has.errors(function() s:write_header("foo\r\n", "bar") end)
		assert.has.errors(function() s:write_header("f\r\noo", "bar") end)
		-- odd values
		assert.has.errors(function() s:write_header("foo") end)
		assert.has.errors(function() s:write_header("foo", "bar\r\n") end)
		assert.has.errors(function() s:write_header("foo", "bar\r\n\r\n") end)
		assert.has.errors(function() s:write_header("foo", "bar\nbad continuation") end)
		assert.has.errors(function() s:write_header("foo", "bar\r\nbad continuation") end)
	end)
	it("chunks round trip", function()
		local s, c = new_pair(1.1)
		assert(c:write_request_line("POST", "/", 1.1))
		assert(c:write_header("Transfer-Encoding", "chunked"))
		assert(c:write_headers_done())
		assert(c:write_body_chunk("this is a chunk"))
		assert(c:write_body_chunk("this is another chunk"))
		assert(c:write_body_last_chunk())
		assert(c:write_headers_done())

		assert(s:read_request_line())
		assert(s:read_header())
		assert(s:read_headers_done())
		assert.same("this is a chunk", s:read_body_chunk())
		assert.same("this is another chunk", s:read_body_chunk())
		assert.same(false, s:read_body_chunk())
		assert(s:read_headers_done())
	end)
end)
describe("high level http1 connection operations", function()
	local h1_connection = require "http.h1_connection"
	local cqueues = require "cqueues"
	local cs = require "cqueues.socket"
	local ce = require "cqueues.errno"

	local function new_pair(version)
		local s, c = cs.pair()
		s = h1_connection.new(s, "server", version)
		c = h1_connection.new(c, "client", version)
		return s, c
	end

	it(":get_next_incoming_stream times out", function()
		local s, c = new_pair(1.1) -- luacheck: ignore 211
		local cq = cqueues.new()
		cq:wrap(function()
			local stream = s:get_next_incoming_stream()
			cqueues.sleep(0.1)
			stream:shutdown()
		end)
		cq:wrap(function()
			cqueues.poll() -- yield so that other thread goes first
			assert.same({nil, ce.ETIMEDOUT}, {s:get_next_incoming_stream(0.05)})
		end)
		assert(cq:loop())
	end)
	it(":get_next_incoming_stream returns nil, EPIPE when no data", function()
		local s, c = new_pair(1.1)
		c:close()
		s:read_status_line() -- do a read option so we note the EOF
		assert.same({nil, ce.EPIPE}, {s:get_next_incoming_stream()})
	end)
end)
