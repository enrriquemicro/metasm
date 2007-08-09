#    This file is part of Metasm, the Ruby assembly manipulation suite
#    Copyright (C) 2007 Yoann GUILLOT
#
#    Licence is LGPL, see LICENCE in the top-level directory


require 'metasm/main'
require 'metasm/parse'


module Metasm
class Preprocessor
	class Macro
		attr_accessor :name, :body, :args, :varargs

		def initialize(name)
			@name = name
			@body = []
		end


		# parses an argument list from the lexer or from a list of tokens
		# modifies the list, returns an array of list of tokens/nil
		# handles nesting
		def self.parse_arglist(lexer, list=nil)
			readtok = proc { list ? list.shift : lexer.readtok(false) }
			unreadtok = proc { |t| list ? (list.unshift(t) if t) : lexer.unreadtok(t) }
			tok = nil
			unreadlist = []
			unreadlist << tok while tok = readtok[] and tok.type == :space
			if not tok or tok.type != :punct or tok.raw != '('
				unreadtok[tok]
				unreadlist.reverse_each { |t| unreadtok[t] }
				return nil
			end
			args = []
			# each argument is any token sequence
			# if it includes an '(' then find the matching ')', whatever is inside (handle nesting)
			# arg cannot include ',' in the top-level
			# args are parsed with no macro expansion
			# convert any space/eol sequence to a single space, strips them at begin/end of argument
			loop do
				arg = []
				nest = 0
				loop do
					raise lexer, 'unterminated arg list' if not tok = readtok[]
					case tok.type
					when :eol, :space
						next if arg.last and arg.last.type == :space
						tok = tok.dup
						tok.type = :space
						tok.raw = ' '
					when :punct
						case tok.raw
						when ',': break if nest == 0
						when ')': break if nest == 0 ; nest -= 1
						when '(': nest += 1
						end
					end
					arg << tok
				end
				arg.pop if arg.last and arg.last.type == :space
				args << arg if not arg.empty? or args.length > 0 or tok.raw != ')'
				break if tok.raw == ')'
			end
			args
		end

		# applies a preprocessor macro
		# parses arguments if needed 
		# macros are lazy
		# fills tokens.expanded_from
		# returns an array of tokens
		def apply(lexer, name, args, list=nil)
			expfrom = name.expanded_from.to_a + [name]
			if args
				# hargs is a hash argname.raw => array of tokens
				hargs = @args.zip(args).inject({}) { |h, (af, ar)| h.update af.raw => ar }

				if not varargs
					raise name, 'invalid argument count' if args.length != @args.length
				else
					raise name, 'invalid argument count' if args.length < @args.length
					virg = name.dup		# concat remaining args in __VA_ARGS__
					virg.type = :punct
					virg.raw = ','
					va = args[@args.length..-1].map { |a| a + [virg.dup] }.flatten
					va.pop
					hargs['__VA_ARGS__'] = va
				end
			else
				hargs = {}
			end

			res = []
			b = @body.map { |t| t = t.dup ; t.expanded_from = expfrom ; t }
			while t = b.shift
				if a = hargs[t.raw]
					# expand macros
					a = a.dup
					while at = a.shift
						margs = nil
						if at.type == :string and am = lexer.definition[at.raw] and not at.expanded_from.to_a.find { |ef| ef.raw == @name.raw } and
								((am.args and margs = Macro.parse_arglist(lexer, a)) or not am.args)
							toks = am.apply(lexer, at, margs, a)
							a = toks + a	# reroll
						else
							res << at.dup if not res.last or res.last.type != :space or at.type != :space
						end
					end
				elsif t.type == :punct and t.raw == '##'
					# the '##' operator: concat the next token to the last in body
					nil while t = b.shift and t.type == :space
					res.pop while res.last and res.last.type == :space
					if not a = hargs[t.raw]
						a = [t]
					end
					if varargs and t.raw == '__VA_ARGS__' and res.last and res.last.type == :punct and res.last.raw == ','
						if args.length == @args.length # pop last , if no vararg passed # XXX poof(1, 2,) != poof(1, 2)
							res.pop
						else # allow merging with ',' without warning
							res.concat a
						end
					else
						a = a[1..-1] if a.first and a.first.type == :space
						if not res.last or res.last.type != :string or not a.first or a.first.type != :string
							puts name.exception("cannot merge token #{res.last.raw} with #{a.first ? a.first.raw : 'nil'}").message if not a.first or (a.first.raw != '.' and res.last.raw != '.') if $VERBOSE
							res.concat a
						else
							res[-1] = res[-1].dup
							res.last.raw << a.first.raw
							res.concat a[1..-1]
						end
					end
				elsif args and t.type == :punct and t.raw == '#' # map an arg to a qstring
					nil while t = b.shift and t.type == :space
					t.type = :quoted
					t.value = hargs[t.raw].map { |aa| aa.raw }.join
					t.value = t.value[1..-1] if t.value[0] == ?\ 	# delete leading space
					t.raw = t.value.inspect
					res << t
				else
					res << t
				end
			end
			res
		end

		# parses the argument list and the body from lexer
		# converts # + # to ## in body
		def parse_definition(lexer)
			varg = nil
			if tok = lexer.readtok_nopp and tok.type == :punct and tok.raw == '('
				@args = []
				loop do
					nil while tok = lexer.readtok_nopp and tok.type == :space
					# check '...'
					if tok and tok.type == :punct and tok.raw == '.'
						t1 = lexer.readtok_nopp
						t2 = lexer.readtok_nopp
						t3 = lexer.readtok_nopp
						t3 = lexer.readtok_nopp while t3 and t3.type == :space
						raise @name, 'booh'  if not t1 or t1.type != :punct or t1.raw != '.' or
									not t2 or t2.type != :punct or t2.raw != '.' or
									not t3 or t3.type != :punct or t3.raw != ')'
						@varargs = true
						break
					end
					break if tok and tok.type == :punct and tok.raw == ')' and @args.empty?	# allow empty list
					raise @name, 'invalid arg definition' if not tok or tok.type != :string
					@args << tok
					nil while tok = lexer.readtok_nopp and tok.type == :space
					# check '...'
					if tok and tok.type == :punct and tok.raw == '.'
						t1 = lexer.readtok_nopp
						t2 = lexer.readtok_nopp
						t3 = lexer.readtok_nopp
						t3 = lexer.readtok_nopp while t3 and t3.type == :space
						raise @name, 'booh'  if not t1 or t1.type != :punct or t1.raw != '.' or
									not t2 or t2.type != :punct or t2.raw != '.' or
									not t3 or t3.type != :punct or t3.raw != ')'
						@varargs = true
						varg = @args.pop.raw
						break
					end
					raise @name, 'invalid arg separator' if not tok or tok.type != :punct or (tok.raw != ')' and tok.raw != ',')
					break if tok.raw == ')'
				end
			else lexer.unreadtok tok
			end

			nil while tok = lexer.readtok_nopp and tok.type == :space
			lexer.unreadtok tok

			while tok = lexer.readtok_nopp
				tok = tok.dup
				case tok.type
				when :eol
					lexer.unreadtok tok
					break
				when :space
					next if @body.last and @body.last.type == :space
					tok.raw = ' '
				when :string
					tok.raw = '__VA_ARGS__' if varg and tok.raw == varg
				when :punct
					if tok.raw == '#'
						ntok = lexer.readtok_nopp
						if ntok and ntok.type == :punct and ntok.raw == '#'
							tok.raw << '#'
						else
							lexer.unreadtok ntok
						end
					end
				end
				@body << tok
			end
			@body.pop if @body.last and @body.last.type == :space

			# check macro is correct
			invalid_body = nil
			if (@body[-1] and @body[-1].raw == '##') or (@body[0] and @body[0].raw == '##')
				invalid_body ||= 'cannot have ## at begin or end of macro body'
				lexer.definition.delete(name.raw)
			end
			if args
				if @args.map { |a| a.raw }.uniq.length != @args.length
					invalid_body ||= 'duplicate macro parameter'
				end
				@body.each_with_index { |tok, i|
					if tok.type == :punct and tok.raw == '#'
						a = @body[i+1]
						a = @body[i+2] if not a or a.type == :space
						if not a.type == :string or (not @args.find { |aa| aa.raw == a.raw } and (not varargs or a.raw != '__VA_ARGS__'))
							invalid_body ||= 'cannot have # followed by non-argument'
						end
					end
				}
				
			end
			if invalid_body
				puts "W: #{lexer.filename}:#{lexer.lineno}, in #{@name.raw}: #{invalid_body}" if $VERBOSE
				lexer.definition.delete(name.raw)
			end
		end

		def dump(comment = true)
			str = ''
			str << "\n// from #{@name.backtrace[-2, 2] * ':'}\n" if comment
			str << "#define #{@name.raw}"
			if args
				str << '(' << (@args.map { |t| t.raw } + (@varargs ? ['...'] : [])).join(', ') << ')'
			end
			str << ' ' << @body.map { |t| t.raw }.join
		end
	end

	# special object, handles __FILE__ __LINE__ __COUNTER__ __DATE__ __TIME__ macros
	class SpecialMacro
		def args ; end
		def body ; [@name] end

		attr_reader :name
		def initialize(raw)
			@name = Token.new(nil)
			@name.type = :string
			@name.raw = raw
		end

		def apply(lexer, name, emptyarglist)
			tok = @name.dup
			tok.expanded_from = name.expanded_from.to_a + [name]
			case @name.raw
			when '__FILE__', '__DATE__', '__TIME__'	# returns a :quoted
				tok.type = :quoted
				tok.value = \
				case @name.raw
				when '__FILE__'
					name = name.expanded_from.first if name.expanded_from
					name.backtrace.to_a[-2].to_s
				when '__DATE__': Time.now.strftime('%b %e %Y')
				when '__TIME__': Time.now.strftime('%H:%M:%S')
				end
				tok.raw = tok.value.inspect
			when '__LINE__', '__COUNTER__'		# returns a :string
				tok.type = :string
				case @name.raw
				when '__LINE__'
					name = name.expanded_from.first if name.expanded_from
					tok.value = name.backtrace.to_a[-1]
				when '__COUNTER__'
					tok.value = @counter ||= 0
					@counter += 1
				end
				tok.raw = tok.value.to_s
			else raise name, 'internal error'
			end
			[tok]
		end
	end

	# a Proc called for unhandled #pragma occurences
	# takes the pragma 1st tok as arg, must unread the final :eol, should fallback to the previous callback
	attr_accessor :pragma_callback
	def initialize
		@queue = []
		@backtrace = []
		@definition = %w[__FILE__ __LINE__ __COUNTER__ __DATE__ __TIME__].inject({}) { |h, n| h.update n => SpecialMacro.new(n) }
		@include_search_path = @@include_search_path
		# stack of :accept/:discard/:discard_all/:testing, represents the current nesting of #if..#endif
		@ifelse_nesting = []
		@text = ''
		@pos = 0
		@filename = nil
		@lineno = nil
		@warn_redefinition = true
		@pragma_callback = proc { |otok|
			tok = otok
			str = tok.raw.dup
			str << tok.raw while tok = readtok and tok.type != :eol
			unreadtok tok
			puts otok.exception("unhandled pragma #{str.inspect}").message if $VERBOSE
		}
		# TODO setup standard macro names ? see $(gcc -dM -E - </dev/null)
	end

	def exception(msg='syntax error')
		backtrace_str = Backtrace.backtrace_str([@filename, @lineno] + @backtrace.map { |f, l, *a| [f, l] }.flatten)
		ParseError.new "at #{backtrace_str}: #{msg}"
	end

	# returns the preprocessed content
	def dump
		ret = ''
		neol = 0
		while not eos?
			t = readtok
			case t.type
			when :space: ret << ' '
			when :eol: ret << "\n" if (neol += 1) <= 2
			when :quoted: neol = 0 ; ret << t.raw	# keep quoted style
			else neol = 0 ; ret << (t.value || t.raw).to_s
			end
		end
		ret
	end

	attr_accessor :traced_macros
	# preprocess text, and retrieve all macros defined in #included <files> and used in the text
	# returns a C source-like string
	def self.factorize(text, comment=false)
		p = new
		p.feed(text)
		p.traced_macros = []
		p.readtok while not p.eos?
		p.dump_macros(p.traced_macros, comment)
	end

	# dumps the definition of the macros whose name is in the list + their dependencies
	# returns one big C-style source string
	def dump_macros(list, comment = true)
		depend = {}
		# build dependency graph (we can output macros in any order, but it's more human-readable)
		walk = proc { |mname|
			depend[mname] ||= []
			@definition[mname].body.each { |t|
				name = t.raw
				if @definition[name]
					depend[mname] << name
					if not depend[name]
						depend[name] = []
						walk[name]
					end
				end
			}
		}
		list.each { |mname| walk[mname] }

		res = []
		while not depend.empty?
			leafs = depend.keys.find_all { |k| depend[k].empty? }
			leafs.each { |l|
				res << @definition[l].dump(comment)
				depend.delete l
			}
			depend.each_key { |k| depend[k] -= leafs }
		end
		res.join("\n")
	end

	# starts a new lexer, with the specified initial filename/line number (for backtraces)
	def feed(text, filename='unknown', lineno=1)
		raise ParseError, 'cannot start new text, did not finish current source' if not eos?
		@text = text
		# @filename[-1] used in trace_macros to distinguish generic/specific files
		@filename = "\"#{filename}\""
		@lineno = lineno
		@pos = 0
		self
	end

	Trigraph = {	?= => ?#, ?) => ?], ?! => ?|,
			?( => ?[, ?' => ?^, ?> => ?},
			?/ => ?\\,?< => ?{, ?- => ?~ }
	
	# reads one character from self.text
	# updates self.lineno
	# handles trigraphs and \-continued lines
	def getchar
		@ungetcharpos = @pos
		@ungetcharlineno = @lineno
		c = @text[@pos]
		@pos += 1

		# check trigraph
		if c == ?? and @text[@pos] == ?? and Trigraph[@text[@pos+1]]
			puts "can i has trigraf plox ??#{c.chr} (#@filename:#@lineno)" if $VERBOSE
			c = Trigraph[@text[@pos+1]]
			@pos += 2
		end

		# check line continuation
		# TODO portability
		if c == ?\\ and (@text[@pos] == ?\n or (@text[@pos] == ?\r and @text[@pos+1] == ?\n))
			@lineno += 1
			@pos += 1 if @text[@pos] == ?\r
			@pos += 1
			return getchar
		end

		if c == ?\r and @text[@pos] == ?\n
			@pos += 1
			c = ?\n
		end

		# update lineno
		if c == ?\n
			@lineno += 1
		end

		c
	end

	def ungetchar
		@pos = @ungetcharpos
		@lineno = @ungetcharlineno
	end

	# returns true if no more data is available
	def eos?
		@pos >= @text.length and @queue.empty? and @backtrace.empty?
	end

	# push back a token, will be returned on the next readtok
	# lifo
	def unreadtok(tok)
		@queue << tok if tok
	end

	# calls readtok_nopp and handles preprocessor directives
	def readtok_cpp(expand_macros = true)
		lastpos = @pos
		tok = readtok_nopp

		if not tok
			# end of file: resume parent
			if not @backtrace.empty?
				raise ParseError, "parse error in #@filename: unmatched #if/#endif" if @backtrace.last.pop != @ifelse_nesting.length
				puts "metasm preprocessor: end of include #@filename, back to #{@backtrace[-1][0]}:#{@backtrace[-1][1]}" if $DEBUG
				@filename, @lineno, @text, @pos, @queue = @backtrace.pop
				tok = readtok
			end

		elsif (tok.type == :eol or lastpos == 0) and @ifelse_nesting.last != :testing
			unreadtok tok if lastpos == 0
			# detect preprocessor directive
			# state = 1 => seen :eol, 2 => seen #
			pretok = []
			rewind = true
			state = 1
			loop do
				pretok << (ntok = readtok_nopp)
				break if not ntok
				if ntok.type == :space	# nothing
				elsif state == 1 and ntok.type == :punct and ntok.raw == '#' and not ntok.expanded_from
					state = 2
				elsif state == 2 and ntok.type == :string and not ntok.expanded_from
					rewind = false if preprocessor_directive(ntok)
					break
				else break
				end
			end
			if rewind
				# false alarm: revert
				pretok.reverse_each { |t| unreadtok t }
			end
			tok = readtok if lastpos == 0	# else return the :eol

		elsif expand_macros and tok.type == :string and m = @definition[tok.raw] and not tok.expanded_from.to_a.find { |ef| ef.raw == m.name.raw } and
				((m.args and margs = Macro.parse_arglist(self)) or not m.args)

			if defined? @traced_macros and tok.backtrace[-2].to_s[0] == ?" and m.name and m.name.backtrace[-2].to_s[0] == ?<
				@traced_macros |= [tok.raw]	# we are in a normal file and expand to an header-defined macro
			end

			m.apply(self, tok, margs).reverse_each { |t| unreadtok t }

			tok = readtok
		end

		tok
	end
	alias readtok readtok_cpp

	# read and return the next token
	# parses quoted strings (set tok.value) and C/C++ comments (:space/:eol)
	def readtok_nopp
		return @queue.pop unless @queue.empty?

		tok = Token.new((@backtrace.map { |bt| bt[0, 2] } + [@filename, @lineno]).flatten)

		case c = getchar
		when nil
			return nil
		when ?', ?"
			# read quoted string value
			tok.type = :quoted
			delimiter = c
			tok.raw << c
			tok.value = ''
			loop do
				raise tok, 'unterminated string' if not c = getchar
				tok.raw << c
				case c
				when delimiter: break
				when ?\\
					raise tok, 'unterminated escape' if not c = getchar
					tok.raw << c
					tok.value << \
					case c
					when ?n: ?\n
					when ?r: ?\r
					when ?t: ?\t
					when ?a: ?\a
					when ?b: ?\b
					when ?v: ?\v
					when ?f: ?\f
					when ?e: ?\e
					when ?#, ?\\, ?', ?": c
					when ?\n: ''	# already handled by getchar
					when ?x:
						hex = ''
						while hex.length < 2
							raise tok, 'unterminated escape' if not c = getchar
							case c
							when ?0..?9, ?a..?f, ?A..?F
							else ungetchar; break
							end
							hex << c
							tok.raw << c
						end
						raise tok, 'unterminated escape' if hex.empty?
						hex.hex
					when ?0..?7:
						oct = '' << c
						while oct.length < 3
							raise tok, 'unterminated escape' if not c = getchar
							case c
							when ?0..?7
							else ungetchar; break
							end
							oct << c
							tok.raw << c
						end
						oct.oct
					else b	# raise tok, 'unknown escape sequence'
					end
				when ?\n: ungetchar ; raise tok, 'unterminated string'
				else tok.value << c
				end
			end

		when ?a..?z, ?A..?Z, ?0..?9, ?$, ?_
			tok.type = :string
			tok.raw << c
			loop do
				case c = getchar
				when nil: ungetchar; break		# avoids 'no method "coerce" for nil' warning
				when ?a..?z, ?A..?Z, ?0..?9, ?$, ?_
					tok.raw << c
				else ungetchar; break
				end
			end

		when ?\ , ?\t, ?\r, ?\n, ?\f
			tok.type = :space
			tok.raw << c
			loop do
				case c = getchar
				when nil: break
				when ?\ , ?\t
				when ?\n, ?\f, ?\r: tok.type = :eol
				else break
				end
				tok.raw << c
			end
			ungetchar
			tok.type = :eol if tok.raw.index(?\n) or tok.raw.index(?\f)

		when ?/
			tok.raw << c
			# comment
			case c = getchar
			when ?/
				# till eol
				tok.type = :eol
				tok.raw << c
				while c = getchar
					tok.raw << c
					break if c == ?\n
				end
			when ?*
				tok.type = :space
				tok.raw << c
				seenstar = false
				loop do
					raise tok, 'unterminated c++ comment' if not c = getchar
					tok.raw << c
					case c
					when ?*: seenstar = true
					when ?/: break if seenstar	# no need to reset seenstar, already false
					else seenstar = false
					end
				end
			else
				# just a slash
				ungetchar
				tok.type = :punct
			end

		else
			tok.type = :punct
			tok.raw << c
		end

		tok
	end

	# defines a simple preprocessor macro (expands to 0 or 1 token)
	def define(name, value=nil)
		raise "redefinition of #{name}" if @definition[name]
		t = Token.new([])
		t.type = :string
		t.raw = name.dup
		@definition[name] = Macro.new(t)
		if value
			t = Token.new([])
			t.type = :string
			t.raw = value.to_s
			@definition[name].body << t
		end
	end

	# handles #directives
	# returns true if the command is valid
	# second parameter for internal use
	def preprocessor_directive(cmd, ocmd = cmd)
		# read spaces, returns the next token
		# XXX for all commands that may change @ifelse_nesting, ensure last element is :testing to disallow any other preprocessor directive to be run in a bad environment (while looking ahead)
		skipspc = proc {
			loop do
				tok = readtok_nopp
				break tok if not tok or tok.type != :space
			end
		}

		# XXX do not preprocess tokens when searching for :eol, it will trigger preprocessor directive detection from readtok_cpp

		eol = tok = nil
		case cmd.raw
		when 'if'
			case @ifelse_nesting.last
			when :accept, nil
				@ifelse_nesting << :testing
				test = PPExpression.parse(self)
				eol = skipspc[]
				raise eol, 'pp syntax error' if eol and eol.type != :eol
				unreadtok eol
				case test.reduce
				when 0:       @ifelse_nesting[-1] = :discard
				when Integer: @ifelse_nesting[-1] = :accept
				else          @ifelse_nesting[-1] = :discard
#				else raise cmd, 'pp cannot evaluate condition ' + test.inspect
				end
			when :discard, :discard_all
				@ifelse_nesting << :discard_all
			end

		when 'ifdef'
			case @ifelse_nesting.last
			when :accept, nil
				@ifelse_nesting << :testing
				raise eol || tok || cmd, 'pp syntax error' if not tok = skipspc[] or tok.type != :string or (eol = skipspc[] and eol.type != :eol)
				unreadtok eol
				@ifelse_nesting[-1] = (@definition[tok.raw] ? :accept : :discard)
			when :discard, :discard_all
				@ifelse_nesting << :discard_all
			end

		when 'ifndef'
			case @ifelse_nesting.last
			when :accept, nil
				@ifelse_nesting << :testing
				raise eol || tok || cmd, 'pp syntax error' if not tok = skipspc[] or tok.type != :string or (eol = skipspc[] and eol.type != :eol)
				unreadtok eol
				@ifelse_nesting[-1] = (@definition[tok.raw] ? :discard : :accept)
			when :discard, :discard_all
				@ifelse_nesting << :discard_all
			end

		when 'elif'
			case @ifelse_nesting.last
			when :accept
				@ifelse_nesting[-1] = :discard_all
			when :discard
				@ifelse_nesting[-1] = :testing
				test = PPExpression.parse(self)
				raise eol, 'pp syntax error' if eol = skipspc[] and eol.type != :eol
				unreadtok eol
				case test.reduce
				when 0:       @ifelse_nesting[-1] = :discard
				when Integer: @ifelse_nesting[-1] = :accept
				else          @ifelse_nesting[-1] = :discard
#				else raise cmd, 'pp cannot evaluate condition ' + test.inspect
				end
			when :discard_all
			else raise cmd, 'pp syntax error'
			end

		when 'else'
			@ifelse_nesting << :testing
			@ifelse_nesting.pop
			raise eol || cmd, 'pp syntax error' if @ifelse_nesting.empty? or (eol = skipspc[] and eol.type != :eol)
			unreadtok eol
			case @ifelse_nesting.last
			when :accept
				@ifelse_nesting[-1] = :discard_all
			when :discard
				@ifelse_nesting[-1] = :accept
			when :discard_all
			end

		when 'endif'
			@ifelse_nesting << :testing
			@ifelse_nesting.pop
			raise eol || cmd, 'pp syntax error' if @ifelse_nesting.empty? or (eol = skipspc[] and eol.type != :eol)
			unreadtok eol
			@ifelse_nesting.pop

		when 'define'
			return if @ifelse_nesting.last and @ifelse_nesting.last != :accept

			raise tok || cmd, 'pp syntax error' if not tok = skipspc[] or tok.type != :string
			puts "W: pp: redefinition of #{tok.raw} at #{tok.backtrace_str},\n prev def at #{@definition[tok.raw].name.backtrace_str}" if @definition[tok.raw] and $VERBOSE and @warn_redefinition
			@definition[tok.raw] = Macro.new(tok)
			@definition[tok.raw].parse_definition(self)

		when 'undef'
			return if @ifelse_nesting.last and @ifelse_nesting.last != :accept

			raise eol || tok || cmd, 'pp syntax error' if not tok = skipspc[] or tok.type != :string or (eol = skipspc[] and eol.type != :eol)
			@definition.delete tok.raw
			unreadtok eol

		when 'include'
			return if @ifelse_nesting.last and @ifelse_nesting.last != :accept

			raise cmd, 'nested too deeply' if backtrace.length > 200	# gcc
	
			# allow preprocessing
			nil while tok = readtok and tok.type == :space
			raise tok || cmd, 'pp syntax error' if not tok or (tok.type != :quoted and (tok.type != :punct or tok.raw != '<'))
			if tok.type == :quoted
				ipath = tok.value
				if @backtrace.find { |btf, *a| btf[0] == ?< }
					# XXX local include from a std include... (kikoo windows.h !)
					dir = @include_search_path.find { |d| ::File.exist? ::File.join(d, ipath) }
					path = ::File.join(dir, ipath) if dir
				elsif ipath[0] != ?/
					path = ::File.join(::File.dirname(@filename[1..-2]), ipath) if ipath[0] != ?/
				else
					path = ipath
				end
			else
				# no more preprocessing : allow comments/multiple space/etc
				ipath = ''
				while tok = readtok_nopp and (tok.type != :punct or tok.raw != '>')
					raise cmd, 'syntax error' if tok.type == :eol
					ipath << tok.raw
				end
				raise cmd, 'pp syntax error, unterminated path' if not tok
				if ipath[0] != ?/
					dir = @include_search_path.find { |d| ::File.exist? ::File.join(d, ipath) }
					path = ::File.join(dir, ipath) if dir
				end
			end
			nil while tok = readtok_nopp and tok.type == :space
			raise tok if tok and tok.type != :eol
			unreadtok tok

			if not defined? @pragma_once or not @pragma_once or not @pragma_once[path]
				puts "metasm preprocessor: including #{path}" if $DEBUG
				raise cmd, "No such file or directory #{ipath.inspect}" if not path or not ::File.exist? path
				raise cmd, 'filename too long' if path.length > 4096		# gcc

				@backtrace << [@filename, @lineno, @text, @pos, @queue, @ifelse_nesting.length]
				# @filename[-1] used in trace_macros to distinguish generic/specific files
				if tok.type == :quoted
					@filename = '"' + path + '"'
				else
					@filename = '<' + path + '>'
				end
				@lineno = 1
				@text = ::File.read(path)
				@pos = 0
				@queue = []
			else
				puts "metasm preprocessor: not reincluding #{path} (pragma once)" if $DEBUG
			end

		when 'error', 'warning'
			return if @ifelse_nesting.last and @ifelse_nesting.last != :accept
			msg = ''
			while tok = readtok_nopp and tok.type != :eol
				msg << tok.raw
			end
			unreadtok tok
			if cmd.raw == 'warning'
				puts cmd.exception("#warning#{msg}").message if $VERBOSE
			else
				raise cmd, "#error#{msg}"
			end

		when 'line'
			return if @ifelse_nesting.last and @ifelse_nesting.last != :accept

			nil while tok = readtok_nopp and tok.type == :space
			raise tok || cmd if not tok or tok.type != :string or tok.raw != tok.raw.to_i.to_s
			@lineno = tok.raw.to_i
			nil while tok = readtok_nopp and tok.type == :space
			raise tok if tok and tok.type != :eol
			unreadtok tok

		when 'pragma'
			return if @ifelse_nesting.last and @ifelse_nesting.last != :accept

			nil while tok = readtok and tok.type == :space
			raise tok || cmd if not tok or tok.type != :string

			case tok.raw
			when 'once'
				(@pragma_once ||= {})[@filename[1..-2]] = true
			when 'no_warn_redefinition'
				@warn_redefinition = false
			when 'include_dir'
				nil while dir = readtok and dir.type == :space
				raise cmd, 'qstring expected' if not dir or dir.type != :quoted
				raise cmd, 'invalid path' if not ::File.directory? dir.value
				@include_search_path.unshift dir.value

			when 'push_macro'
				@pragma_macro_stack ||= []
				nil while lp = readtok and lp.type == :space
				nil while m = readtok and m.type == :space
				nil while rp = readtok and rp.type == :space
				raise cmd if not rp or lp.type != :punct or rp.type != :punct or lp.raw != '(' or rp.raw != ')' or m.type != :quoted
				mbody = @definition[m.value]
				@pragma_macro_stack << mbody

			when 'pop_macro'
				@pragma_macro_stack ||= []
				nil while lp = readtok and lp.type == :space
				nil while m = readtok and m.type == :space
				nil while rp = readtok and rp.type == :space
				raise cmd if not rp or lp.type != :punct or rp.type != :punct or lp.raw != '(' or rp.raw != ')' or m.type != :quoted
				raise cmd, "macro stack empty" if @pragma_macro_stack.empty?
				# pushing undefined macro name is allowed, handled here
				mbody = @pragma_macro_stack.pop
				if mbody
					@definition[m.value] = mbody
				else
					@definition.delete m.value
				end
			
			else
				@pragma_callback[tok]
			end

			nil while tok = readtok_nopp and tok.type == :space
			raise tok if tok and tok.type != :eol
			unreadtok tok

		else return false
		end

		# skip #undef'd parts of the source
		state = 1	# just seen :eol
		while @ifelse_nesting.last == :discard or @ifelse_nesting.last == :discard_all
			begin 
				tok = skipspc[]
			rescue ParseError
				# react as gcc -E: " unterminated in #undef => ok, /* unterminated => error (the " will fail at eol)
				retry
			end

			if not tok: raise ocmd, 'pp unterminated conditional'
			elsif tok.type == :eol: state = 1
			elsif state == 1 and tok.type == :punct and tok.raw == '#': state = 2
			elsif state == 2 and tok.type == :string: state = preprocessor_directive(tok, ocmd) ? 1 : 0
			else state = 0
			end
		end

		true
	end

# parses a preprocessor expression (similar to Expression, + handles "defined(foo)")
class PPExpression
	class << self
		# reads an operator from the lexer, returns the corresponding symbol or nil
		def readop(lexer)
			if not tok = lexer.readtok or tok.type != :punct
				lexer.unreadtok tok
				return
			end

			op = tok
			case op.raw
			# may be followed by itself or '='
			when '>', '<'
				if ntok = lexer.readtok and ntok.type == :punct and (ntok.raw == op.raw or ntok.raw == '=')
					op = op.dup
					op.raw << ntok.raw
				else
					lexer.unreadtok ntok
				end
			# may be followed by itself
			when '|', '&'
				if ntok = lexer.readtok and ntok.type == :punct and ntok.raw == op.raw
					op = op.dup
					op.raw << ntok.raw
				else
					lexer.unreadtok ntok
				end
			# must be followed by '='
			when '!', '='
				if not ntok = lexer.readtok or ntok.type != :punct and ntok.raw != '='
					lexer.unreadtok ntok
					lexer.unreadtok tok
					return
				end
				op = op.dup
				op.raw << ntok.raw
			# ok
			when '^', '+', '-', '*', '/', '%'
			# unknown
			else
				lexer.unreadtok tok
				return
			end
			op.value = op.raw.to_sym
			op
		end

		# handles floats and "defined" keyword
		def parse_intfloat(lexer, tok)
			if tok.type == :string and tok.raw == 'defined'
				nil while ntok = lexer.readtok_nopp and ntok.type == :space
				raise tok if not ntok
				if ntok.type == :punct and ntok.raw == '('
					nil while ntok = lexer.readtok_nopp and ntok.type == :space
					nil while rtok = lexer.readtok_nopp and rtok.type == :space
					raise tok if not rtok or rtok.type != :punct or rtok.raw != ')'
				end
				raise tok if not ntok or ntok.type != :string
				tok.value = lexer.definition[ntok.raw] ? 1 : 0
				return 
			end

			Expression.parse_num_value(lexer, tok)
		end

		# returns the next value from lexer (parenthesised expression, immediate, variable, unary operators)
		# single-line only, and does not handle multibyte char string
		def parse_value(lexer)
			nil while tok = lexer.readtok and tok.type == :space
			return if not tok
			case tok.type
			when :string
				parse_intfloat(lexer, tok)
				val = tok.value || tok.raw
			when :quoted
				if tok.raw[0] != ?' or tok.value.length > 1	# allow single-char
					lexer.unreadtok tok
					return
				end
				val = tok.value[0]
			when :punct
				case tok.raw
				when '('
					nil while ntok = lexer.readtok and ntok.type == :space
					lexer.unreadtok ntok
					val = parse(lexer)
					nil while ntok = lexer.readtok and ntok.type == :space
					raise tok, "syntax error, no ) found after #{val.inspect}, got #{ntok.inspect}" if not ntok or ntok.type != :punct or ntok.raw != ')'
				when '!', '+', '-', '~'
					nil while ntok = lexer.readtok and ntok.type == :space
					lexer.unreadtok ntok
					raise tok, 'need expression after unary operator' if not val = parse_value(lexer)
					val = Expression[tok.raw.to_sym, val]
				when '.'
					parse_intfloat(lexer, tok)
					if not tok.value
						lexer.unreadtok tok
						return
					end
					val = tok.value
				else
					lexer.unreadtok tok
					return
				end
			else
				lexer.unreadtok tok
				return
			end
			nil while tok = lexer.readtok and tok.type == :space
			lexer.unreadtok tok
			val
		end

		# for boolean operators, true is 1 (or anything != 0), false is 0
		def parse(lexer)
			opstack = []
			stack = []

			return if not e = parse_value(lexer)

			stack << e

			while op = readop(lexer)
				nil while ntok = lexer.readtok and ntok.type == :space
				lexer.unreadtok ntok
				until opstack.empty? or Expression::OP_PRIO[op.value][opstack.last]
					stack << Expression.new(opstack.pop, stack.pop, stack.pop)
				end
				
				opstack << op.value
				
				raise op, 'need rhs' if not e = parse_value(lexer)

				stack << e
			end

			until opstack.empty?
				stack << Expression.new(opstack.pop, stack.pop, stack.pop)
			end

			Expression[stack.first]
		end
	end
end
end
end
