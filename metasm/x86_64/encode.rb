#    This file is part of Metasm, the Ruby assembly manipulation suite
#    Copyright (C) 2009 Yoann GUILLOT
#
#    Licence is LGPL, see LICENCE in the top-level directory


require 'metasm/x86_64/opcodes'
require 'metasm/x86_64/parse'
require 'metasm/encode'

module Metasm
class X86_64
	class ModRM
		def encode(reg = 0, endianness = :little)
			reg = reg.val if reg.kind_of? Argument

			ret = EncodedData.new << (reg << 3)

			# add bits in the first octet of ret.data (1.9 compatibility layer)
			or_bits = lambda { |v|	# rape me
				if ret.data[0].kind_of? Integer
					ret.data[0] |= v
				else
					ret.data[0] = (ret.data[0].ord | v).chr
				end
			}

			if not self.b and not self.i
				# imm only, use sib
				or_bits[4]
				imm = self.imm || Expression[0]
				[ret << ((4 << 3) | 5) << imm.encode(:i32, endianness)]

			elsif self.b.val == 16	# rip+imm
				# TODO [1*rip+28]
				raise if self.i	# XXX check
				or_bits[5]
				imm = self.imm || Expression[0]
				[ret << imm.encode(:i32, endianness)]

			elsif not self.b and self.s != 1
				# sib with no b
				raise EncodeError, "Invalid ModRM #{self}" if @i.val == 4	# XXX 12 ?
				or_bits[4]
				s = {8=>3, 4=>2, 2=>1}[@s]
				imm = self.imm || Expression[0]
				[ret << ((s << 6) | (@i.val_enc << 3) | 5) << imm.encode(:i32, endianness)]
			else
				imm = @imm.reduce if self.imm
				imm = nil if imm == 0

				if not self.i or (not self.b and self.s == 1)
					# no sib byte (except for [esp])
					b = self.b || self.i

					or_bits[b.val_enc]
					ret << 0x24 if b.val == 4	# XXX val_enc ?
				else
					# sib
					or_bits[4]

					i, b = @i, @b
					b, i = i, b if @s == 1 and (i.val == 4 or b.val == 5)

					raise EncodeError, "Invalid ModRM #{self}" if i.val == 4

					s = {8=>3, 4=>2, 2=>1, 1=>0}[@s]
					ret << ((s << 6) | (i.val_enc << 3) | b.val_enc)
				end

				imm ||= 0 if b.val_enc == 5
				if imm
					case Expression.in_range?(imm, :i8)
					when true
						or_bits[1<<6]
						[ret << Expression.encode_imm(imm, :i8, endianness)]
					when false
						or_bits[2<<6]
						[ret << Expression.encode_imm(imm, :a32, endianness)]
					when nil
						rets = ret.dup
						or_bits[1<<6]
						ret << @imm.encode(:i8, endianness)
						rets, ret = ret, rets	# or_bits[] modifies ret directly
						or_bits[2<<6]
						ret << @imm.encode(:a32, endianness)
						[ret, rets]
					end
				else
					[ret]
				end
			end
		end
	end

	# returns all forms of the encoding of instruction i using opcode op
	# program may be used to create a new label for relative jump/call
	def encode_instr_op(program, i, op)
		base      = op.bin.dup
		oi        = op.args.zip(i.args)
		set_field = lambda { |f, v|
			fld = op.fields[f]
			base[fld[0]] |= v << fld[1]
		}

		#
		# handle prefixes and bit fields
		#
		pfx = i.prefix.map { |k, v|
			case k
			when :jmp;  {:jmp => 0x3e, :nojmp => 0x2e}[v]
			when :lock; 0xf0
			when :rep;  {'repnz' => 0xf2, 'repz' => 0xf3, 'rep' => 0xf2}[v] # TODO
			end
		}.compact.pack 'C*'
		pfx << op.props[:needpfx] if op.props[:needpfx]

		rex_w = rex_r = rex_x = rex_b = nil
		if op.name == 'movsx' or op.name == 'movzx'
			case i.args[0].sz
			when 64; rex_w = 1
			when 32
			when 16; pfx << 0x66
			end
		else
			opsz = op.props[:argsz] || i.prefix[:sz]
			oi.each { |oa, ia|
				case oa
				when :reg, :reg_eax, :modrm, :modrmA, :mrm_imm
					raise EncodeError, "Incompatible arg size in #{i}" if ia.sz and opsz and opsz != ia.sz
					opsz = ia.sz
				end
			}
			opsz = op.props[:opsz] if op.props[:opsz]	# XXX ?
			case opsz
			when 64; rex_w = 1	# TODO check autopromoted opcodes (push etc)
			when 32
			when 16; pfx << 0x66
			end
		end
		opsz ||= @size

		# addrsize override / segment override / rex_bx
		if mrm = i.args.grep(ModRM).first
			mrm.encode(0, @endianness)	# may reorder b/i, which must be correct for rex
			rex_b = 1 if mrm.b and mrm.b.val_rex.to_i > 0
			rex_x = 1 if mrm.i and mrm.i.val_rex.to_i > 0
			if (mrm.b and mrm.b.sz == 32) or (mrm.i and mrm.i.sz == 32)
				pfx << 0x67
				adsz = 32	# XXX used only with mrm_imm (mov eax, [addr])
			end
			pfx << [0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65][mrm.seg.val] if mrm.seg
		elsif op.props[:adsz] and op.propz[:adsz] == 32
			pfx << 0x67
			adsz = 32
		end
		adsz ||= @size


		#
		# encode embedded arguments
		#
		postponed = []
		oi.each { |oa, ia|
			case oa
			when :reg
				set_field[oa, ia.val_enc]
				rex_r = ia.val_rex	# TODO ah bh vs rex
			when :seg3, :seg3A, :seg2, :seg2A, :eeec, :eeed, :regxmm
				set_field[oa, ia.val & 7]
				rex_r = 1 if ia.val > 7
			when :imm_val1, :imm_val3, :reg_cl, :reg_eax, :reg_dx, :regfp0
				# implicit
			else
				postponed << [oa, ia]
			end
		}

		if !(op.args & [:modrm, :modrmA, :modrmxmm]).empty?
			# reg field of modrm
			regval = (base[-1] >> 3) & 7
			base.pop
		end

		# convert label name for jmp/call/loop to relative offset
		if op.props[:setip] and op.name[0, 3] != 'ret' and i.args.first.kind_of? Expression
			postlabel = program.new_label('post'+op.name)
			target = postponed.first[1]
			target = target.rexpr if target.kind_of? Expression and target.op == :+ and not target.lexpr
			postponed.first[1] = Expression[target, :-, postlabel]
		end

		if rex_w or rex_r or rex_b or rex_x
			rex ||= 0x40
			rex |= 1 if rex_b.to_i > 0
			rex |= 2 if rex_x.to_i > 0
			rex |= 4 if rex_r.to_i > 0
			rex |= 8 if rex_w.to_i > 0
		end
		pfx << rex if rex
		ret = EncodedData.new(pfx + base.pack('C*'))

		postponed.each { |oa, ia|
			case oa
			when :farptr; ed = ia.encode(@endianness, "a#{opsz}".to_sym)
			when :modrm, :modrmA, :modrmmmx, :modrmxmm
				if ia.kind_of? ModRM
					ed = ia.encode(regval, @endianness)
					if ed.kind_of?(::Array)
						if ed.length > 1
							# we know that no opcode can have more than 1 modrm
							ary = []
							ed.each { |m| ary << (ret.dup << m) }
							ret = ary
							next
						else
							ed = ed.first
						end
					end
				else
					ed = ModRM.encode_reg(ia, regval)
				end
			when :mrm_imm; ed = ia.imm.encode("a#{adsz}".to_sym, @endianness)
			when :i8, :u8, :i16, :u16, :i32, :u32, :i64, :u64; ed = ia.encode(oa, @endianness)
			when :i; ed = ia.encode(:i32, @endianness)	# XXX :a32 ?
			else raise SyntaxError, "Internal error: want to encode field #{oa.inspect} as arg in #{i}"
			end

			if ret.kind_of?(::Array)
				ret.each { |e| e << ed }
			else
				ret << ed
			end
		}

		# we know that no opcode with setip accept both modrm and immediate arg, so ret is not an ::Array
		ret.add_export(postlabel, ret.virtsize) if postlabel

		ret
	end
end
end
