#    This file is part of Metasm, the Ruby assembly manipulation suite
#    Copyright (C) 2006-2009 Yoann GUILLOT
#
#    Licence is LGPL, see LICENCE in the top-level directory

module Metasm
module GtkGui
class AsmListingWidget < DrawableWidget
	attr_accessor :arrow_zone_w

	def initialize_widget
		@arrows = []	# array of [linefrom, lineto] (may be :up or :down for offscreen)
		@line_address = []
		@line_text = []
		@line_text_color = []
		@want_update_line_text = @want_update_caret = true
		@wantaddr = nil
		@arrow_zone_w = 40

		addrs = @dasm.sections.keys.grep(Integer)
		@minaddr = addrs.min
		@maxaddr = addrs.max + @dasm.sections[addrs.max].length rescue nil
		@startaddr = @dasm.prog_binding['entrypoint'] || @minaddr || 0

		@default_color_association = { :comment => :darkblue, :label => :darkgreen, :text => :black,
			  :instruction => :black, :address => :blue, :caret => :black,
			  :background => :white, :cursorline_bg => :paleyellow, :hl_word => :palered,
			  :arrows_bg => :palegrey, :arrow_up => :darkblue, :arrow_dn => :darkyellow, :arrow_hl => :red }
	end

	def resized(w, h)
		col = w/@font_width
		lin = h/@font_height
		@caret_x = col-1 if @caret_x >= col
		@caret_y = lin-1 if @caret_y >= lin and lin > 0
		gui_update
	end

	def adjust_startaddr(off=0, update = true)
		@startaddr += off
		@startaddr = @maxaddr - 1 if @startaddr >= @maxaddr
		if off = (0..16).find { |off_| di = @dasm.decoded[@startaddr-off_] and di.respond_to? :bin_length and di.bin_length > off_ } and off != 0
			# align on @decoded boundary
			@startaddr -= off
		end
		@startaddr = @minaddr if @startaddr < @minaddr
		gui_update if update
	end

	def click(x, y)
		set_caret_from_click(x - @arrow_zone_w, y)
	end

	def rightclick(x, y)
		click(x, y)
		@parent_widget.clone_window(@hl_word, :listing)
	end

	def doubleclick(x, y)
		click(x, y)
		@parent_widget.focus_addr(@hl_word)
	end

	def mouse_wheel(dir)
		case dir
		when :up
			# TODO handle block start (multiline) / data aggregation (db 100h dup(?), strings..)
			@wantaddr = @line_address[@caret_y]
			adjust_startaddr(-1, false)
			adjust_startaddr(-1, false)
			adjust_startaddr(-1, false)
			adjust_startaddr(-1)
		when :down
			# scroll down 4 lines, or more if all the 4 1st lines have the same addr (eg block start)
			@wantaddr = @line_address[@caret_y]
			a = @line_address[4..-1].find { |v| v > @line_address[0] } if @line_address[4]
			@startaddr = a || (@startaddr + 4)
			adjust_startaddr
		end
	end

	# renders the disassembler from @startaddr
	def paint
		w_w = width
		w_h = height

		# arrow bg
		draw_rectangle_color(:arrows_bg, 0, 0, @arrow_zone_w, w_h)

		# TODO scroll line-by-line when an addr is displayed on multiple lines (eg labels/comments)
		# TODO selection

		update_line_text if @want_update_line_text
		update_caret if @want_update_caret

		if @parent_widget.bg_color_callback
			ly = 0
			@line_address.each { |a|
				if c = @parent_widget.bg_color_callback[a]
					draw_rectangle_color(c, 0, ly*@font_height, w_w, @font_height)
				end
				ly += 1
			}
		end

		# current window position
		x = @arrow_zone_w + 1
		y = 0

		# renders a string at current cursor position with a color
		# must not include newline
		render = lambda { |str, color|
			# function ends when we write under the bottom of the listing
			next if not str or y >= w_h or x >= w_w
			if @hl_word
				stmp = str
				pre_x = 0
				while stmp =~ /^(.*?)(\b#{Regexp.escape @hl_word}\b)/
					s1, s2 = $1, $2
					pre_x += s1.length * @font_width
					hl_x = s2.length * @font_width
					draw_rectangle_color(:hl_word, x+pre_x, y, hl_x, @font_height)
					pre_x += hl_x
					stmp = stmp[s1.length+s2.length..-1]
				end
			end
			draw_string_color(color, x, y, str)
			x += str.length * @font_width
		}

		# draw caret line background
		draw_rectangle_color(:cursorline_bg, 0, @caret_y*@font_height, w_w, @font_height)

		@line_text_color.each { |a|
			render[a[0], :address]
			render[a[1], :label]
			render[a[2], :instruction]
			render[a[3], :comment]
			x = @arrow_zone_w + 1
			y += @font_height
		}

		if focus?
			cx = @arrow_zone_w + @caret_x*@font_width+1
			cy = @caret_y*@font_height
			draw_line_color(:caret, cx, cy, cx, cy+@font_height-1)
		end

		paint_arrows
	end

	# draws the @arrows defined in paint_listing
	def paint_arrows
		return if @arrows.empty? or not @line_address[0]
		w_w, w_h = @arrow_zone_w, height

		slot_alloc = {}	# [y1, y2] => x slot	-- y1 <= y2
		# find a free x slot for the vertical side of the arrow
		max = (w_w-6)/3
		find_free = lambda { |y1, y2|
			y1, y2 = y2, y1 if y2 < y1
			slot_alloc[[y1, y2]] = (0...max).find { |off|
				not slot_alloc.find { |(oy1, oy2), oo|
					# return true if this slot cannot share with off
					next if oo != off	# not same slot => ok
					next if oy1 == y1 and y1 != 0		# same upbound & in window
					next if oy2 == y2 and y2 != w_h-1	# same lowbound & in window
					# check overlapping segment
					(y1 >= oy1 and y1 <= oy2) or
					(y2 >= oy1 and y2 <= oy2) or
					(oy1 >= y1 and oy1 <= y2) or
					(oy2 >= y1 and oy2 <= y2)
				}
			} || (max-1)
		}

		# alloc slots for arrows, starts by the smallest
		arrs = { :arrow_dn => [], :arrow_up => [], :arrow_hl => [] }
		@arrows.sort_by { |from, to|
			if from.kind_of? Numeric and to.kind_of? Numeric
				(from-to).abs
			else
				100000
			end
		}.each { |from, to|
			y1 = case from
			when :up; 0
			when :down; w_h-1
			else from * @font_height + @font_height/2 - 1
			end
			y2 = case to
			when :up; 0
			when :down; w_h-1
			else to * @font_height + @font_height/2 - 1
			end
			if y1 <= y2
				y1 += 2 if y1 != 0
			else
				y1 -= 2 if y1 != w_h-1
			end

			col = :arrow_dn
			col = :arrow_up if y1 > y2
			col = :arrow_hl if (from.kind_of? Integer and @line_address[from] == @line_address[@caret_y]) or
					(to.kind_of? Integer and @line_address[to] == @line_address[@caret_y])
			arrs[col] << [y1, y2, find_free[y1, y2]]
		}

		slot_w = (w_w-4)/slot_alloc.values.uniq.length
		# draw arrows (hl last to overwrite)
		[:arrow_dn, :arrow_up, :arrow_hl].each { |col|
			draw_color(col)
			arrs[col].each { |y1, y2, slot|
				x1 = w_w-1
				x2 = w_w-4 - slot*slot_w - slot_w/2

				draw_line(x1, y1, x2, y1) if y1 != 0 and y1 != w_h-1
				draw_line(x2, y1, x2, y2)
				draw_line(x2, y2, x1, y2) if y2 != 0 and y2 != w_h-1
				draw_line(x1, y2, x1-3, y2-3) if y2 != 0 and y2 != w_h-1
				draw_line(x1, y2, x1-3, y2+3) if y2 != 0 and y2 != w_h-1
			}
		}
	end

	# if curaddr points to an instruction, find the next data, else find the next instruction
	def move_to_next
		a = current_address
		if not @dasm.get_section_at(a)
			a = @dasm.sections.map { |k, e| k }.find_all { |k| k > a }.min
		elsif @dasm.decoded[a].kind_of? DecodedInstruction
			while @dasm.decoded[a].kind_of? DecodedInstruction
				a = @dasm.decoded[a].block.list.last.next_addr
			end
		else
			a = @dasm.decoded.keys.find_all { |k| k > a }.min
		end
		@parent_widget.focus_addr(a) if a
	end

	# see move_to_next
	def move_to_prev
		a = current_address
		if not @dasm.get_section_at(a)
			a = @dasm.sections.map { |k, e| k }.find_all { |k| k < a }.max
			a += @dasm.get_section_at(a)[0].length - 1 if a
		elsif @dasm.decoded[a].kind_of? DecodedInstruction
			while @dasm.decoded[a].kind_of? DecodedInstruction
				a = @dasm.decoded[a].block.list.first.address
				if off = (1..16).find { |off_|
						@dasm.decoded[a-off_].kind_of? DecodedInstruction and
						@dasm.decoded[a-off_].next_addr == a }
					a -= off
				else
					a -= 1
				end
			end
		else
			a = @dasm.decoded.keys.find_all { |k| k < a }.max
		end
		@parent_widget.focus_addr(a) if a
	end

	def keypress_ctrl(key)
		case key
		when ?n; move_to_next ; true
		when ?p; move_to_prev ; true
		end
	end

	def keypress(key)
		case key
		when :left
			if @caret_x >= 1
				@caret_x -= 1
				update_caret
			end
		when :up
			if @caret_y > 1 or (@caret_y == 1 and @startaddr == @minaddr)
				@caret_y -= 1
			else
				adjust_startaddr(-1)
			end
			update_caret
		when :right
			if @caret_x < @line_text[@caret_y].to_s.length
				@caret_x += 1
				update_caret
			end
		when :down
			if @caret_y < @line_address.length-3 or (@caret_y < @line_address.length - 2 and @startaddr == @maxaddr)
				@caret_y += 1
			else
				if a = @line_address[0] and na = @line_address.find { |na_| na_ != a }
					@startaddr = na
					gui_update
				else
					adjust_startaddr(1)
				end
			end
			update_caret
		when :pgup
			adjust_startaddr(-15)
		when :pgdown
			@startaddr = @line_address[@line_address.length/2] || @startaddr + 15
			gui_update
		when :home
			@caret_x = 0
			update_caret
		when :end
			@caret_x = @line_text[@caret_y].to_s.length
			update_caret
		else return
		end
		true
	end

	def get_cursor_pos
		[@startaddr, @caret_x, @caret_y]
	end

	def set_cursor_pos(p)
		@startaddr, @caret_x, @caret_y = p
		gui_update
	end

	# hint that the caret moved
	# redraws the caret, change the hilighted word, redraw if needed
	def update_caret
		if @want_update_line_text
			@want_update_caret = true
			return
		end
		return if not @line_text[@caret_y]
		@want_update_caret = false
		if update_hl_word(@line_text[@caret_y], @caret_x) or @oldcaret_y != @caret_y or true
			redraw
		else
			return if @oldcaret_x == @caret_x and @oldcaret_y == @caret_y

			invalidate_caret(@oldcaret_x, @oldcaret_y, @arrow_zone_w, 0)
			invalidate_caret(@caret_x, @caret_y, @arrow_zone_w, 0)

			if @arrows.find { |f, t| f == @caret_y or t == @caret_y or f == @oldcaret_y or t == @oldcaret_y }
				invalidate(0, 0, @arrow_zone_w, 1000000)
			end
		end
		@parent_widget.focus_changed_callback[] if @parent_widget.focus_changed_callback and @oldcaret_y != @caret_y

		@oldcaret_x = @caret_x
		@oldcaret_y = @caret_y
	end

	# focus on addr
	# addr may be a dasm label, dasm address, dasm address in string form (eg "0DEADBEEFh")
	# may scroll the window
	# returns true on success (address exists)
	def focus_addr(addr)
		return if not addr = @parent_widget.normalize(addr)
		if l = @line_address.index(addr) and l < @line_address.length - 4
			@caret_y, @caret_x = @line_address.rindex(addr), 0
		elsif addr >= @minaddr and addr <= @maxaddr
			@startaddr, @caret_x, @caret_y = addr, 0, 0
			adjust_startaddr
			@wantaddr = @startaddr
			@line_address[@caret_y] = @startaddr	# so that right after focus_addr(42) ; self.current_address => 42 (coverage sync)
		else
			return
		end
		update_caret
		true
	end

	# returns the address of the data under the cursor
	def current_address
		@line_address[@caret_y] || -1
	end

	# reads @dasm to update @line_text_color/@line_text/@line_address/@arrows
	def update_line_text
		return if not w = window

		addrs = @dasm.sections.keys.grep(Integer)
		@minaddr = addrs.min
		@maxaddr = addrs.max + @dasm.sections[addrs.max].length rescue nil

		@want_update_line_text = false

		w_h = (height + @font_height - 1) / @font_height

		curaddr = @startaddr

		@line_address.clear
		@line_text.clear
		@line_text_color.clear	# list of [addr, label, text, comment]

		line = 0

		# list of arrows to draw ([addr_from, addr_to])
		arrows_addr = []

		str_c = []

		nl = lambda {
			@line_address[line] = curaddr
			@line_text[line] = str_c.join
			@line_text_color[line] = str_c
			str_c = []
			line += 1
		}

		while line < w_h
			if di = @dasm.decoded[curaddr] and di.kind_of? DecodedInstruction
				if di.block_head?
					# render dump_block_header, add a few colors
					b_header = '' ; @dasm.dump_block_header(di.block) { |l| b_header << l ; b_header << ?\n if b_header[-1] != ?\n }
					b_header.each { |l|
						l.chomp!
						cmt = (l[0, 2] == '//' or l[-1] != ?:)
						str_c[cmt ? 3 : 1] = l	# cmt || label
						nl[]
					}
					# ary
					di.block.each_from_samefunc(@dasm) { |addr|
						addr = @dasm.normalize addr
						next if not addr.kind_of? ::Integer or (@dasm.decoded[addr].kind_of? DecodedInstruction and @dasm.decoded[addr].next_addr == curaddr)
						arrows_addr << [addr, curaddr]
					}
				end
				if di.block.list.last == di
					di.block.each_to_samefunc(@dasm) { |addr|
						addr = @dasm.normalize addr
						next if not addr.kind_of? ::Integer or (di.next_addr == addr and
								(not di.opcode.props[:saveip] or di.block.to_subfuncret))
						arrows_addr << [curaddr, addr]
					}
				end
				str_c << "#{Expression[di.address]}    "
				str_c << nil
				str_c << "#{di.instruction} ".ljust(di.comment ? 24 : 0)
				str_c << " ; #{di.comment.join(' ')}" if di.comment
				nl[]

				# instr overlapping
				if off = (1...di.bin_length).find { |off_| @dasm.decoded[curaddr + off_] }
					nl[]
					curaddr += off
					str_c[3] = "// ------ overlap (#{di.bin_length - off}) ------"
					nl[]
				else
					curaddr += [di.bin_length, 1].max
				end
			elsif curaddr < @maxaddr and s = @dasm.get_section_at(curaddr) and s[0].ptr < s[0].length
				@dasm.comment[curaddr].each { |c| str_c[3] = "// #{c}" ; nl[] } if @dasm.comment[curaddr]
				if label = s[0].inv_export[s[0].ptr]
					l_list = @dasm.label_alias[curaddr].sort
					label = l_list.pop
					nl[] if not l_list.empty?
					l_list.each { |name|
						str_c[1] = "#{name}:"
						nl[]
					}
				end
				str_c << "#{Expression[curaddr]}    "
				str_c << ("#{label} " if label)

				# TODO cache len for next line (when most lines are db 1 db 2 db 3)
				len = 256
				len = (1..len).find { |l| @dasm.xrefs[curaddr+l] or s[0].inv_export[s[0].ptr+l] or s[0].reloc[s[0].ptr+l] } || len
				comment = nil
				if s[0].data.length > s[0].ptr
					str = s[0].read(len).unpack('C*')
					s[0].ptr -= len		# we may not display the whole bunch, ptr is advanced later
					if @dasm.xrefs[curaddr] or rel = s[0].reloc[s[0].ptr]
						len = rel.length if rel
						comment = []
						@dasm.each_xref(curaddr) { |xref|
							len = xref.len if xref.len
							comment << " #{xref.type}#{xref.len}:#{Expression[xref.origin]}" if xref.origin
						} if @dasm.xrefs[curaddr]
						comment = nil if comment.empty?
						str = str.pack('C*').unpack(@dasm.cpu.endianness == :big ? 'n*' : 'v*') if len == 2
						if (len == 1 or len == 2) and asc = str.inject('') { |asc_, c|
								case c
								when 0x20..0x7e, 9, 10, 13; asc_ << c
								else break asc_
								end
							} and asc.length >= 1
							dat = "#{len == 1 ? 'db' : 'dw'} #{asc.inspect} "
							aoff = asc.length * len
						else
							len = 1 if (len != 2 and len != 4 and len != 8) or len < 1
							dat = "#{%w[x db dw x dd x x x dq][len]} #{Expression[s[0].decode_imm("u#{len*8}".to_sym, @dasm.cpu.endianness)]} "
							aoff = len
						end
					elsif rep = str.inject(0) { |rep_, c|
						case c
						when str[0]; rep_+1
						else break rep_
						end
					} and rep > 4
						rep -= curaddr % 256 if rep == 256 and curaddr.kind_of? Integer
						dat = "db #{Expression[rep]} dup(#{Expression[str[0]]}) "
						aoff = rep
					elsif asc = str.inject('') { |asc_, c|
						case c
						when 0x20..0x7e, 9, 10, 13; asc_ << c
						else break asc_
						end
					} and asc.length > 3
						dat = "db #{asc.inspect} "
						aoff = asc.length
					else
						dat = "db #{Expression[str[0]]} "
						aoff = 1
					end
				else
					if @dasm.xrefs[curaddr]
						comment = []
						@dasm.each_xref(curaddr) { |xref|
							len = xref.len if xref.len
							comment << " #{xref.type}#{xref.len}:#{Expression[xref.origin]} "
						}
						len = 1 if (len != 2 and len != 4 and len != 8) or len < 1
						dat = "#{%w[x db dw x dd x x x dq][len]} ? "
						aoff = len
					else
						len = [len, s[0].length-s[0].ptr].min
						len -= curaddr % 256 if len == 256 and curaddr.kind_of? Integer
						dat = "db #{Expression[len]} dup(?) "
						aoff = len
					end
				end
				str_c << dat.ljust(comment ? 24 : 0)
				str_c << " ; #{comment.join(' ')}" if comment
				nl[]
				curaddr += aoff
			else
				nl[]
				curaddr += 1
			end
		end
		@line_address[w_h..-1] = [] if @line_address.length >= w_h
		@caret_y = @line_address.rindex(@wantaddr) || @caret_y if @wantaddr
		@wantaddr = nil

		# convert arrows_addr to @arrows (with line numbers)
		# updates @arrows_widget if @arrows changed
		prev_arrows = @arrows
		addr_line = {}		# addr => last line (di)
		@line_address.each_with_index { |a, l| addr_line[a] = l }
		@arrows = arrows_addr.uniq.sort.map { |from, to|
			[(addr_line[from] || (from < curaddr ? :up : :down)),
			 (addr_line[ to ] || ( to  < curaddr ? :up : :down))]
		}
		invalidate(0, 0, @arrow_zone_w, 100000) if prev_arrows != @arrows
	end

	def gui_update
		@want_update_line_text = true
		redraw
	end
end
end
end
