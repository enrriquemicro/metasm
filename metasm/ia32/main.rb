#    This file is part of Metasm, the Ruby assembly manipulation suite
#    Copyright (C) 2007 Yoann GUILLOT
#
#    Licence is LGPL, see LICENCE in the top-level directory


require 'metasm/main'

module Metasm
class Ia32 < CPU

	# some ruby magic
	class Argument
		@simple_list = []
		@double_list = []
		class << self
			# for Argument
			attr_reader :simple_list, :double_list
			# for subclasses
			attr_reader :i_to_s, :s_to_i
		end

		private
		def self.simple_map(a)
			Argument.simple_list << self

			@i_to_s = Hash[*a.flatten]
			@s_to_i = @i_to_s.invert

			class_eval {
				attr_accessor :val
				def initialize(v)
					raise Exception, "invalid #{self.class} #{v}" unless self.class.i_to_s[v]
					@val = v
				end

				def self.from_str(s) new(@s_to_i[s]) end
			}
		end

		def self.double_map(h)
			Argument.double_list << self

			@i_to_s = h
			@s_to_i = {} ; h.each { |sz, hh| hh.each_with_index { |r, i| @s_to_i[r] = [i, sz] } }

			class_eval {
				attr_accessor :val, :sz
				def initialize(v, sz)
					raise Exception, "invalid #{self.class} #{sz}/#{v}" unless self.class.i_to_s[sz] and self.class.i_to_s[sz][v]
					@val = v
					@sz = sz
				end

				def self.from_str(s)
					raise "Bad #{name} #{s.inspect}" if not x = @s_to_i[s]
					new(*x)
				end
			}
		end

	end


	class SegReg < Argument
		simple_map((0..5).zip(%w(es cs ss ds fs gs)))
	end

	class DbgReg < Argument
		simple_map [0, 1, 2, 3, 6, 7].map { |i| [i, "dr#{i}"] }
	end

	class CtrlReg < Argument
		simple_map [0, 2, 3, 4].map { |i| [i, "cr#{i}"] }
	end

	class FpReg < Argument
		simple_map((0..7).map { |i| [i, "ST(#{i})"] } << [nil, 'ST'])
	end

	class SimdReg < Argument
		double_map  64 => (0..7).map { |n| "mm#{n}" },
			   128 => (0..7).map { |n| "xmm#{n}" }
		def symbolic ; to_s.to_sym end
	end

	class Reg < Argument
		double_map  8 => %w{ al  cl  dl  bl  ah  ch  dh  bh},
			   16 => %w{ ax  cx  dx  bx  sp  bp  si  di},
			   32 => %w{eax ecx edx ebx esp ebp esi edi}
			  #64 => %w{rax rcx rdx rbx rsp rbp rsi rdi}

		Sym = @i_to_s[32].map { |s| s.to_sym }
		def symbolic
			s = Sym[@val]
			if @sz == 8 and to_s[-1] == ?h
				Expression[[Sym[@val-4], :>>, 8], :&, 0xff]
			elsif @sz == 8
				Expression[s, :&, 0xff]
			elsif @sz == 16
				Expression[s, :&, 0xffff]
			else
				Sym[@val]
			end
		end

		# checks if two registers have bits in common
		def share?(other)
			other.val % (other.sz >> 1) == @val % (@sz >> 1) and (other.sz != @sz or @sz != 8 or other.val == @val)
		end
	end

	class Farptr < Argument
		attr_reader :seg, :addr
		def initialize(seg, addr)
			@seg, @addr = seg, addr
		end
	end

	class ModRM < Argument
		Sum = {
		    16 => {
			0 => [ [3, 6], [3, 7], [5, 6], [5, 7], [6], [7], [:i16], [3] ],
			1 => [ [3, 6, :i8 ], [3, 7, :i8 ], [5, 6, :i8 ], [5, 7, :i8 ], [6, :i8 ], [7, :i8 ], [5, :i8 ], [3, :i8 ] ],
			2 => [ [3, 6, :i16], [3, 7, :i16], [5, 6, :i16], [5, 7, :i16], [6, :i16], [7, :i16], [5, :i16], [3, :i16] ]
		    },
		    32 => {
			0 => [ [0], [1], [2], [3], [:sib], [:i32], [6], [7] ],
			1 => [ [0, :i8 ], [1, :i8 ], [2, :i8 ], [3, :i8 ], [:sib, :i8 ], [5, :i8 ], [6, :i8 ], [7, :i8 ] ],
			2 => [ [0, :i32], [1, :i32], [2, :i32], [3, :i32], [:sib, :i32], [5, :i32], [6, :i32], [7, :i32] ]
		    }
		}


		attr_accessor :adsz, :sz
		attr_accessor :seg
		attr_accessor :s, :i, :b, :imm

		def initialize(adsz, sz, s, i, b, imm, seg = nil)
			@adsz, @sz = adsz, sz
			@s, @i = s, i if i
			@b = b if b
			@imm = imm if imm
			@seg = seg if seg
		end

		def symbolic(orig=nil)
			p = nil
			p = Expression[p, :+, @b.symbolic] if b
			p = Expression[p, :+, [@s, :*, @i.symbolic]] if i
			p = Expression[p, :+, @imm] if imm
			p = Expression["segment_base_#@seg", :+, p] if seg and seg.val != ((b && (@b.val == 4 || @b.val == 5)) ? 2 : 3)
			Indirection[p.reduce, @sz/8, orig]
		end
	end

	def initialize(family = :latest, size = 32)
		super()
		@endianness = :little
		@size = size
		send "init_#{family}"
		init_backtrace_binding
	end

	def tune_cparser(cp)
		super
		cp.lexer.define_weak('_M_IX86', 500)
		cp.lexer.define_weak('_X86_')
		cp.lexer.define_weak('__i386__')
	end
end

end
