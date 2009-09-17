#    This file is part of Metasm, the Ruby assembly manipulation suite
#    Copyright (C) 2006-2009 Yoann GUILLOT
#
#    Licence is LGPL, see LICENCE in the top-level directory


module Metasm
# this module regroups OS-related functions
# (eg. find_process, inject_shellcode)
# a 'class' just to be able to inherit from it...
class OS
	# represents a running process with a few information, and defines methods to get more interaction (#memory, #debugger)
	class Process
		attr_accessor :pid, :modules
		class Module
			attr_accessor :path, :addr
		end
		def to_s
			mod = File.basename(@modules.first.path) if modules and @modules.first and @modules.first.path
			"#{pid}: ".ljust(6) << (mod || '<unknown>')
		end
		def inspect
			'<Process:' + ["pid: #@pid", modules.to_a.map { |m| " #{'%X' % m.addr} #{m.path}" }].join("\n") + '>'
		end
	end

	# returns the Process whose pid is name (if name is an Integer) or first module path includes name (string)
	def self.find_process(name)
		case name
		when nil
		when Integer
			list_processes.find { |pr| pr.pid == name }
		else
			list_processes.find { |pr| m = pr.modules.to_a.first and m.path.include? name.to_s } or
				(find_process(Integer(name)) if name =~ /^(0x[0-9a-f]+|[0-9]+)$/i)
		end
	end

	# create a new debuggee process stopped at start
	def self.create_process(path)
		dbg = create_debugger(path)
		pr = find_process(dbg.pid)
		pr.debugger = dbg
		pr.memory = dbg.memory
		pr
	end

	# return the platform-specific version
	def self.current
		case RUBY_PLATFORM
		when /mswin32/; WinOS
		when /linux/; LinOS
		end
	end
end

# This class implements an objects that behaves like a regular string, but
# whose real data is dynamically fetched or generated on demand
# its size is immutable
# implements a page cache
# substrings are Strings (small substring) or another VirtualString
# (a kind of 'window' on the original VString, when the substring length is > 4096)
class VirtualString
	# formats parameters for reading
	def [](from, len=nil)
		if not len and from.kind_of? Range
			b = from.begin
			e = from.end
			b = 1 + b + length if b < 0
			e = 1 + e + length if e < 0
			len = e - b
			len += 1 if not from.exclude_end?
			from = b
		end
		from = 1 + from + length if from < 0

		return nil if from > length or (from == length and not len)
		len = length - from if len and from + len > length
		return '' if len == 0

		read_range(from, len)
	end

	# formats parameters for overwriting portion of the string
	def []=(from, len, val=nil)
		raise TypeError, 'cannot modify frozen virtualstring' if frozen?

		if not val
			val = len
			len = nil
		end
		if not len and from.kind_of? Range
			b = from.begin
			e = from.end
			b = b + length if b < 0
			e = e + length if e < 0
			len = e - b
			len += 1 if not from.exclude_end?
			from = b
		elsif not len
			len = 1
			val = val.chr
		end
		from = from + length if from < 0

		raise IndexError, 'Index out of string' if from > length
		raise IndexError, 'Cannot modify virtualstring length' if val.length != len or from + len > length

		write_range(from, val)
	end

	# returns the full raw data
	def realstring
		ret = ''
		addr = 0
		len = length
		while len > @pagelength
			ret << self[addr, @pagelength]
			addr += @pagelength
			len -= @pagelength
		end
		ret << self[addr, len]
	end

	# alias to realstring
	# for bad people checking respond_to? :to_str (like String#<<)
	# XXX alias does not work (not virtual (a la C++))
	def to_str
		realstring
	end

	# forwards unhandled messages to a frozen realstring
	def method_missing(m, *args, &b)
		if ''.respond_to? m
			puts "Using VirtualString.realstring for #{m} from:", caller if $DEBUG
			realstring.freeze.send(m, *args, &b)
		else
			super(m, *args, &b)
		end
	end

	# avoid triggering realstring from method_missing if possible
	def empty?
		length == 0
	end

	# avoid triggering realstring from method_missing if possible
	# heavily used in to find 0-terminated strings in ExeFormats
	def index(chr, base=0)
		return if base >= length or base <= -length
		if i = self[base, 64].index(chr) or i = self[base, @pagelength].index(chr)
			base + i
		else
			realstring.index(chr, base)
		end
	end

	# implements a read page cache

	# the real address of our first byte
	attr_accessor :addr_start
	# our length
	attr_accessor :length
	# array of [addr, raw data], sorted by first == last accessed
	attr_accessor :pagecache
	# maximum length of self.pagecache (number of cached pages)
	attr_accessor :pagecache_len
	def initialize(addr_start, length)
		@addr_start = addr_start
		@length = length
		@pagecache = []
		@pagecache_len = 4
		@pagelength ||= 4096	# must be (1 << x)
		@invalid_page_addr = nil
	end

	# returns wether a page is valid or not
	def page_invalid?(addr)
		cache_get_page(@addr_start+addr)[2]
	end

	# invalidates the page cache
	def invalidate
		@pagecache.clear
	end

	# returns the @pagelength-bytes page starting at addr
	# return nil if the page is invalid/inaccessible
	# addr is page-aligned by the caller
	# addr is absolute
	#def get_page(addr, len=@pagelength)
	#end

	# searches the cache for a page containing addr, updates if not found
	def cache_get_page(addr)
		addr &= ~(@pagelength-1)
		i = 0
		@pagecache.each { |c|
			if addr == c[0]
				# most recently used first
				@pagecache.unshift @pagecache.delete_at(i) if i != 0
				return c
			end
			i += 1
		}
		@pagecache.pop if @pagecache.length >= @pagecache_len
		c = [addr]
		p = get_page(addr)
		c << p.to_s.ljust(@pagelength, "\0")
		c << true if not p
		@pagecache.unshift c
		c
	end

	# reads a range from the page cache
	# returns a new VirtualString (using dup) if the request is bigger than @pagelength bytes
	def read_range(from, len)
		from += @addr_start
		base, page = cache_get_page(from)
		if not len
			page[from - base]
		elsif len <= @pagelength
			s = page[from - base, len]
			if from+len-base > @pagelength		# request crosses a page boundary
				base, page = cache_get_page(from+len)
				s << page[0, from+len-base]
			end
			s
		else
			# big request: return a new virtual page
			dup(from, len)
		end
	end

	# rewrites a segment of data
	# the length written is the length of the content (a VirtualString cannot grow/shrink)
	def write_range(from, content)
		invalidate
		rewrite_at(from + @addr_start, content)
	end

	# overwrites a section of the original data
	#def rewrite_at(addr, content)
	#end
end

# on-demand reading of a file
class VirtualFile < VirtualString
	# returns a new VirtualFile of the whole file content (defaults readonly)
	# returns a String if the file is small (<4096o) and readonly access
	def self.read(path, mode='rb')
		raise 'no filename specified' if not path
		if sz = File.size(path) <= 4096 and (mode == 'rb' or mode == 'r')
			File.open(path, mode) { |fd| fd.read }
		else
			File.open(path, mode) { |fd| new fd, 0, sz }
		end
	end

	# the underlying file descriptor
	attr_accessor :fd

	# creates a new virtual mapping of a section of the file
	# the file descriptor must be seekable
	def initialize(fd, addr_start = 0, length = nil)
		@fd = fd.dup
		if not length
			@fd.seek(0, File::SEEK_END)
			length = @fd.tell - addr_start
		end
		super(addr_start, length)
	end

	def dup(addr = @addr_start, len = @length)
		self.class.new(@fd, addr, len)
	end

	# reads an aligned page from the file, at file offset addr
	def get_page(addr, len=@pagelength)
		@fd.pos = addr
		@fd.read len
	end

	# overwrite a section of the file
	def rewrite_at(addr, data)
		@fd.pos = addr
		@fd.write data
	end

	# returns the full content of the file
	def realstring
		@fd.pos = @addr_start
		@fd.read(@length)
	end
end

# this class implements a high-level debugging API (abstract superclass)
class Debugger
	class Breakpoint
		attr_accessor :oneshot, :state, :type, :previous, :condition, :action, :mtype, :mlen
	end

	attr_accessor :memory, :cpu, :disassembler, :state, :info, :breakpoint, :pid
	attr_accessor :modulemap, :symbols, :symbols_len

	# initializes the disassembler from @cpu and @memory
	def initialize
		@disassembler = Shellcode.decode(EncodedData.new(@memory), @cpu).init_disassembler
		@modulemap = {}
		@symbols = {}
		@symbols_len = {}
		@breakpoint = {}
		@state = :stopped
		@info = nil
		@log_proc = nil
	end

	def set_log_proc(l=nil, &b)
		@log_proc = l || b
	end

	def puts(*a)
		if @log_proc
			a.each { @log_proc[a] }
		else
			super(*a)
		end
	end

	def invalidate
		@memory.invalidate
	end

	def pc
		get_reg_value(register_pc)
	end

	def pc=(v)
		set_reg_value(register_pc, v)
	end

	def check_pre_run
		invalidate
		addr = pc
		@breakpoint.each { |a, b|
			next if a == addr or b.state != :inactive
			enable_bp(a)
		}
	end

	def check_post_run(pre_state=nil)
		invalidate
		addr = pc
		@breakpoint.each { |a, b|
			next if a != addr or b.state != :active
			disable_bp(a)
		}
		if b = @breakpoint[addr]
			if b.condition
				cond = resolve_expr(b.condition)
				if cond == 0
					continue if pre_state == 'continue'
					return	# don't delete if we're singlestepping
				end
			end
			@breakpoint.delete(addr) if b.oneshot
			if b.action
				b.action.call :addr => addr, :bp => b, :dbg => self, :pre_state => pre_state
			end
		end
	end

	def check_target
		pre_state = @info
		t = do_check_target
		check_post_run(pre_state) if @state == :stopped
		t
	end

	def wait_target
		t = do_wait_target
		check_post_run if @state == :stopped
		t
	end

	def continue(*a)
		while @breakpoint[pc]
			do_singlestep	# XXX *a ?
			do_wait_target	# TODO async wait if curinstr is syscall(sleep 3600)...
		end
		check_pre_run	# re-set bp
		do_continue(*a)
	end

	def singlestep(*a)
		check_pre_run
		do_singlestep(*a)
	end

	def run
		continue
	end

	# keep the debugee running until it's dead
	def run_forever
		while @state != :dead
			run
			wait_target
		end
	end

	def need_stepover(di)
		di and @cpu.dbg_need_stepover(self, di.address, di)
	end

	def di_at(addr)
		if not di = @disassembler.decoded[addr]
			return if not s = @disassembler.get_section_at(addr)
			di = @cpu.decode_instruction(s[0], addr)
		end
		di
	end

	def stepover
		check_pre_run
		di = di_at(pc)
		if need_stepover(di)
			bpx di.next_addr, true
			do_continue
		else
			do_singlestep
		end
	end

	def end_stepout(di)
		di and @cpu.dbg_end_stepout(self, di.address, di)
	end

	# stepover until finding the last instruction of the function
	def stepout
		while not end_stepout(di_at(pc))
			stepover
			wait_target
		end
		do_singlestep
	end

	def add_bp(addr, type, oneshot, cond, act, mtype=nil, mlen=nil)
		if b = @breakpoint[addr]
			b.oneshot = false if not oneshot
			raise 'bp type conflict' if type != b.type
			raise 'bp condition conflict' if cond != b.condition
			raise 'bp action conflict' if act != b.action
			return
		end
		b = Breakpoint.new
		b.oneshot = oneshot
		b.type = type
		b.condition = cond if cond
		b.action = act if act
		b.mtype = mtype if mtype
		b.mlen = mlen if mlen
		@breakpoint[addr] = b
		enable_bp(addr)
	end

	def bpx(addr, oneshot=false, cond=nil, &action)
		add_bp(addr, :bpx, oneshot, cond, action)
	end

	def hwbp(addr, mtype=:x, mlen=1, oneshot=false, cond=nil, &action)
		add_bp(addr, :hw, oneshot, cond, action, mtype, mlen)
	end

	def remove_breakpoint(addr)
		disable_bp(addr)
		@breakpoint.delete addr
	end

	def detach
		@breakpoint.each_key { |a| disable_bp(addr) }
	end

	def register_list
		@cpu.dbg_register_list
	end

	def register_size
		@cpu.dbg_register_size
	end

	def register_pc
		@cpu.dbg_register_pc
	end

	def register_flags
		@cpu.dbg_register_flags
	end

	def flag_list
		@cpu.dbg_flag_list
	end

	def get_flag_value(f)
		@cpu.dbg_get_flag(self, f)
	end
	alias get_flag get_flag_value

	def set_flag_value(f, v)
		v != 0 ? set_flag(f) : unset_flag(f)
	end

	def toggle_flag(f)
		set_flag_value(f, 1-get_flag_value(f))
	end

	def set_flag(f)
		@cpu.dbg_set_flag(self, f)
	end

	def unset_flag(f)
		@cpu.dbg_unset_flag(self, f)
	end

	# returns the name of the module containing addr
	def findmodule(addr)
		@modulemap.keys.find { |k| @modulemap[k][0] <= addr and @modulemap[k][1] > addr } || '???'
	end

	# returns a string describing addr in term of symbol (eg 'libc.so.6!printf+2f')
	def addrname(addr)
		findmodule(addr) + '!' +
		if s = @symbols[addr] ? addr : @symbols_len.keys.find { |s_| s_ < addr and s_ + @symbols_len[s_] > addr }
			@symbols[s] + (addr == s ? '' : ('+%x' % (addr-s)))
		else '%08x' % addr
		end
	end

	# same as addrname, but check prev addresses if no symbol matches
	def addrname!(addr)
		findmodule(addr) + '!' +
		if s = @symbols[addr] ? addr : @symbols_len.keys.find { |s_| s_ < addr and s_ + @symbols_len[s_] > addr } || @symbols.keys.sort.find_all { |s_| s_ < addr and s_ + 0x10000 > addr }.max
			@symbols[s] + (addr == s ? '' : ('+%x' % (addr-s)))
		else '%08x' % addr
		end
	end

	# loads the symbols from a mapped module (each name loaded only once)
	def loadsyms(addr, name='%08x'%addr)
		return if not peek = @memory.get_page(addr, 4)
		if peek == AutoExe::ELFMAGIC
			cls = LoadedELF
		elsif peek[0, 2] == AutoExe::MZMAGIC and @memory[addr+@memory[addr+0x3c,4].unpack('V').first, 4] == AutoExe::PEMAGIC
			cls = LoadedPE
		else return
		end

		@loadedsyms ||= {}
		return if @loadedsyms[name]
		@loadedsyms[name] = true

		begin
			e = cls.load @memory[addr, 0x1000_0000]
			e.load_address = addr
			e.decode_header
			e.decode_exports
		rescue
			@modulemap[addr.to_s(16)] = [addr, addr+0x1000]
			return
		end

		if n = e.module_name and n != name
			name = n
			return if @loadedsyms[name]
			@loadedsyms[name] = true
		end

		@modulemap[name] = [addr, addr+e.module_size]

		sl = @symbols.length
		e.module_symbols.each { |n_, a, l|
			a += addr
			@disassembler.set_label_at(a, n_)
			@symbols[a] = n_
			if l and l > 1; @symbols_len[a] = l
			else @symbols_len.delete a	# we may overwrite an existing symbol, keep len in sync
			end
		}
		puts "loaded #{@symbols.length - sl} symbols from #{name}" if $VERBOSE

		true
	end

	def scansyms
		addr = 0
		while addr <= 0xffff_f000
			loadsyms(addr)
			addr += 0x1000
		end
	end

	def loadallsyms
		OS.current.find_process(@pid).modules.to_a.each { |m| loadsyms(m.addr, m.path) }
	end

	# an Expression whose ::parser handles indirection (byte ptr [foobar])
	class IndExpression < Expression
		class << self
		def parse_value(lexer)
			sz = nil
			ptr = nil
			loop do
				nil while tok = lexer.readtok and tok.type == :space
				return if not tok
				case tok.raw
				when 'qword'; sz=8
				when 'dword'; sz=4
				when 'word'; sz=2
				when 'byte'; sz=1
				when 'ptr'
				when '['
					ptr = parse(lexer)
					nil while tok = lexer.readtok and tok.type == :space
					raise tok || lexer, '] expected' if tok.raw != ']'
					break
				when '*'
					ptr = parse(lexer)
					break
				when ':'
					n = lexer.readtok
					return n.raw.to_sym
				else
					lexer.unreadtok tok
					break
				end
			end
			raise lexer, 'invalid indirection' if sz and not ptr
			if ptr; Indirection[ptr, sz]	# if sz is nil, default cpu pointersz is set in resolve_expr
			else super(lexer)
			end
		end

		def parse(*a, &b)
			# custom decimal converter
			@cb_hex = b
			super(*a)
		end

		def parse_intfloat(lexer, tok)
			case tok.raw
			when /^([0-9]+)$/; tok.value = @cb_hex ? @cb_hex[$1] : $1.to_i
			when /^0x([0-9a-f]+)$/i, /^([0-9a-f]+)h$/i; tok.value = $1.to_i(16)
			when /^0b([01]+)$/i; tok.value = $1.to_i(2)
			end
		end

		def readop(lexer)
			if t0 = lexer.readtok and t0.raw == '-' and t1 = lexer.readtok and t1.raw == '>'
				op = t0.dup
				op.raw << t1.raw
				op.value = op.raw.to_sym
				op
			else
				lexer.unreadtok t1
				lexer.unreadtok t0
				super(lexer)
			end
		end

		def new(op, r, l)
			return Indirection[[l, :+, r], nil] if op == :'->'
			super(op, r, l)
		end
		end
	end

	# parses the expression contained in arg, updates arg to point after the expr
	def parse_expr(arg)
		pp = Preprocessor.new(arg)
		return if not e = IndExpression.parse(pp) { |s|
			# handle 400000 -> 0x400000
			# XXX no way to override and force decimal interpretation..
			if s.length > 4 and not @disassembler.get_section_at(s.to_i) and @disassembler.get_section_at(s.to_i(16))
				s.to_i(16)
			else
				s.to_i
			end
		}

		# update arg
		len = pp.pos
		pp.queue.each { |t| len -= t.raw.length }
		arg[0, len] = ''

		# resolve ambiguous symbol names/hex values
		bd = {}
		e.externals.grep(String).each { |ex|
			if not v = register_list.find { |r| ex.downcase == r.to_s.downcase } ||
						(block_given? && yield(ex)) || symbols.index(ex)
				lst = symbols.values.find_all { |s| s.downcase.include? ex.downcase }
				case lst.length
				when 0
					if ex =~ /^[0-9a-f]+$/i and @disassembler.get_section_at(ex.to_i(16))
						v = ex.to_i(16)
					else
						puts "unknown symbol name #{ex}"
						raise "unknown symbol name #{ex}"
					end
				when 1
					v = symbols.index(lst.first)
					puts "using #{lst.first} for #{ex}"
				else
					puts "ambiguous #{ex}: #{lst.join(', ')} ?"
					raise "ambiguous symbol name #{ex}"
				end
			end
			bd[ex] = v
		}
		e = e.bind(bd)

		e
	end

	# resolves an expression involving register values and/or memory indirection using the current context
	# uses #register_list, #get_reg_value, @mem, @cpu
	def resolve_expr(e)
		bd = {}
		Expression[e].externals.each { |ex|
			next if bd[ex]
			case ex
			when ::Symbol; bd[ex] = get_reg_value(ex)
			when ::String; bd[ex] = @symbols.index(ex) || 0
			end
		}
		Expression[e].bind(bd).reduce { |i|
			if i.kind_of? Indirection and p = i.pointer.reduce and p.kind_of? ::Integer
				i.len ||= @cpu.size/8
				p &= (1 << @cpu.size) - 1 if p < 0
				Expression.decode_imm(@memory, i.len, @cpu, p)
			end
		}
	end
end

end
