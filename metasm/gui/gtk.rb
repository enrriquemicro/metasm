#    This file is part of Metasm, the Ruby assembly manipulation suite
#    Copyright (C) 2007 Yoann GUILLOT
#
#    Licence is LGPL, see LICENCE in the top-level directory


require 'gtk2'
require 'metasm/gui/gtk_listing'
require 'metasm/gui/gtk_graph'
require 'metasm/gui/gtk_decomp'

module Metasm
module GtkGui
class DisasmWidget < Gtk::VBox
	attr_accessor :dasm, :entrypoints, :views, :gui_update_counter_max, :notebook
	# hash key_val => lambda { |keyb_ev| true if handled }
	attr_accessor :keyboard_callback

	def initialize(dasm, ep=[])
		super()

		@dasm = dasm
		@entrypoints = ep
		@views = []
		@pos_history = []
		@gui_update_counter_max = 100
		@keyboard_callback = {}

		gui_update_counter = 0
		dasm_working = false
		@gtk_idle_handle = Gtk.idle_add {
			# metasm disassembler loop
			# update gui once in a while
			dasm_working = true if not @entrypoints.empty? or not @dasm.addrs_todo.empty?
			if dasm_working
				begin
					if not @dasm.disassemble_mainiter(@entrypoints)
						dasm_working = false
						gui_update_counter = @gui_update_counter_max
					end
				rescue Object
					messagebox [$!, $!.backtrace].join("\n")
				end
				gui_update_counter += 1
				if gui_update_counter > @gui_update_counter_max
					gui_update_counter = 0
					gui_update
				end
			end
			true
		}

		@dasm.callback_prebacktrace ||= lambda { Gtk.main_iteration_do(false) }

		#pack_start iconbar, dasm_working_flag ?

		@notebook = Gtk::Notebook.new
		# hex view
		pack_start @notebook

		@notebook.show_border = false
		@notebook.show_tabs = false

		@views << AsmListingWidget.new(@dasm, self)
		@views << GraphViewWidget.new(@dasm, self)
		@views << CdecompListingWidget.new(@dasm, self)
		@notebook.append_page(@views[0], Gtk::Label.new('listing'))
		@notebook.append_page(@views[1], Gtk::Label.new('graph'))
		@notebook.append_page(@views[2], Gtk::Label.new('decomp'))

		@notebook.focus_child = curview
	end

	def terminate
		Gtk.idle_remove @gtk_idle_handle
	end

	def curview
		@views[@notebook.page]
	end

	include Gdk::Keyval
	def keypress(ev)
		return true if @keyboard_callback[ev.keyval] and @keyboard_callback[ev.keyval].call(ev)
	    case ev.state & Gdk::Window::CONTROL_MASK
	    when Gdk::Window::CONTROL_MASK
		case ev.keyval
		when GDK_r	# run arbitrary ruby
			inputbox('ruby code to eval()') { |c|
				begin
					ret = eval c
					messagebox ret.inspect[0, 128], 'eval'
				rescue Object
					messagebox "#$! #{$!.message}\n#{$!.backtrace.join("\n")}", 'eval error'
				end
			}
		end
	    when 0
		case ev.keyval
		when GDK_Return, GDK_KP_Enter
			focus_addr curview.hl_word
		when GDK_Escape
			focus_addr_back
		when GDK_c	# disassemble from this point
				# if points to a call, make it return
			return if not addr = curview.current_address
			if di = @dasm.decoded[addr] and di.kind_of? DecodedInstruction and di.opcode.props[:saveip] and not @dasm.decoded[addr + di.bin_length]
				di.block.add_to_subfuncret(addr+di.bin_length)
				@dasm.addrs_todo << [addr + di.bin_length, addr, true]
			else
				@dasm.addrs_todo << [addr]
			end
		when GDK_f	# list functions
			list = [['name', 'addr']]
			@dasm.function.keys.each { |f|
				addr = @dasm.normalize(f)
				next if not @dasm.decoded[addr]
				list << [@dasm.prog_binding.index(addr), Expression[addr]]
			}
			title = "list of functions"
			listwindow(title, list) { |i| focus_addr i[1] }
		when GDK_g	# jump to address
			inputbox('address to go') { |v| focus_addr v }
		when GDK_h	# parses a C header
			openfile('open C header') { |f|
				@dasm.parse_c_file(f) rescue messagebox("#{$!}\n#{$!.backtrace}")
			}
		when GDK_l	# list labels
			list = [['name', 'addr']]
			@dasm.prog_binding.each { |k, v|
				list << [k, Expression[@dasm.normalize(v)]]
			}
			listwindow("list of labels", list) { |i| focus_addr i[1] }
		when GDK_n	# name/rename a label
			if not curview.hl_word or not addr = @dasm.prog_binding[curview.hl_word]
				return if not addr = curview.current_address
			end
			if old = @dasm.prog_binding.index(addr)
				inputbox("new name for #{old}") { |v| @dasm.rename_label(old, v) ; gui_update }
			else
				inputbox("label name for #{Expression[addr]}") { |v| @dasm.set_label_at(addr, v) ; gui_update }
			end
		when GDK_p	# pause/play disassembler
			@dasm_pause ||= []
			if @dasm_pause.empty? and @dasm.addrs_todo.empty?
			elsif @dasm_pause.empty?
				@dasm_pause = @dasm.addrs_todo.dup
				@dasm.addrs_todo.clear
				puts "dasm paused (#{@dasm_pause.length})"
			else
				@dasm.addrs_todo.concat @dasm_pause
				@dasm_pause.clear
				puts "dasm restarted (#{@dasm.addrs_todo.length})"
			end
		when GDK_v	# toggle verbose flag
			$VERBOSE = ! $VERBOSE
			puts "verbose #$VERBOSE"
		when GDK_x      # show xrefs to the current address
			return if not addr = @dasm.prog_binding[curview.hl_word] || curview.current_address
			list = [['address', 'type', 'instr']]
			@dasm.each_xref(addr) { |xr|
				list << [Expression[xr.origin], "#{xr.type}#{xr.len}"]
				if di = @dasm.decoded[xr.origin] and di.kind_of? DecodedInstruction
					list.last << di.instruction
				end
			}
			title = "list of xrefs to #{Expression[addr]}"
			if list.length == 1
				messagebox "no xref to #{Expression[addr]}"
			else
				listwindow(title, list) { |i| focus_addr(i[0], nil, true) }
			end

		when GDK_space
			focus_addr(curview.current_address, ((@notebook.page == 1) ? 0 : 1))
		when GDK_Tab
			focus_addr(curview.current_address, ((@notebook.page == 2) ? 0 : 2))

		when 0x20..0x7e # normal kbd (use ascii code)
			# quiet
			return false
		when GDK_Shift_L, GDK_Shift_R, GDK_Control_L, GDK_Control_R,
				GDK_Alt_L, GDK_Alt_R, GDK_Meta_L, GDK_Meta_R,
				GDK_Super_L, GDK_Super_R, GDK_Menu
			# quiet
			return false
		else
			c = Gdk::Keyval.constants.find { |c_| Gdk::Keyval.const_get(c_) == ev.keyval }
			p [:unknown_keypress, ev.keyval, c, ev.state]
			return false
		end
	    end		# ctrl/alt
		true
	end

	def focus_addr(addr, page=nil, quiet=false)
		page ||= @notebook.page
		case addr
		when ::String
			if @dasm.prog_binding[addr]
				addr = @dasm.prog_binding[addr]
			elsif (?0..?9).include? addr[0]
				case addr
				when /^0x/i
				when /h$/; addr = '0x' + addr[0...-1]
				when /[a-f]/i; addr = '0x' + addr
				end
				begin
					addr = Integer(addr)
				rescue ::ArgumentError
					messagebox "Invalid address #{addr}" if not quiet
					return
				end
			else
				messagebox "Invalid address #{addr}" if not quiet
				return
			end
		when nil; return
		end

		return if page == @notebook.page and addr == curview.current_address
		oldpos = [@notebook.page, curview.get_cursor_pos]
		@notebook.page = page
		if (curview.focus_addr(addr) rescue nil) or (0...@views.length).find { |v|
			o_p = @views[v].get_cursor_pos
			if (@views[v].focus_addr(addr) rescue nil)
				@notebook.page = v
				true
			else
				@views[v].set_cursor_pos o_p
				false
			end
		}
			@pos_history << oldpos
			true
		else
			messagebox "Invalid address #{Expression[addr]}" if not quiet
			focus_addr_back oldpos
			false
		end
	end

	def focus_addr_back(val = @pos_history.pop)
		return if not val
		@notebook.page = val[0]
		curview.set_cursor_pos val[1]
		true
	end

	def gui_update
		@views.each { |v| v.gui_update }
	end

	def keep_focus_while
		curaddr = curaddr
		yield
		focus_addr curaddr if curaddr
	end

	# returns the address of the item under the cursor in current view
	def curaddr
		curview.current_address
	end

	# returns the object under the cursor in current view (@dasm.decoded[curaddr])
	def curobj
		@dasm.decoded[curaddr]
	end

	def messagebox(str, title=nil)
		MessageBox.new(toplevel, str, title)
	end

	def inputbox(str, title=nil, &b)
		InputBox.new(toplevel, str, &b)
	end

	def openfile(title, &b)
		OpenFile.new(toplevel, title, &b)
	end

	def listwindow(title, list, &b)
		ListWindow.new(toplevel, title, list, &b)
	end
end

class MessageBox < Gtk::MessageDialog
	# shows a message box (non-modal)
	def initialize(owner, str, title=nil)
		owner ||= Gtk::Window.toplevels.first
		super(owner, Gtk::Dialog::DESTROY_WITH_PARENT, INFO, BUTTONS_CLOSE, str)
		self.title = title if title
		signal_connect('response') { destroy }
		show_all
		present		# bring the window to the foreground & set focus
	end
end

class InputBox < Gtk::Dialog
	# shows a simplitic input box (eg window with a 1-line textbox + OK button), yields the text
	# TODO history, dropdown, autocomplete, contexts, 3D stereo surround, etc
	def initialize(owner, str, title=nil)
		owner ||= Gtk::Window.toplevels.first
		super(nil, owner, Gtk::Dialog::DESTROY_WITH_PARENT,
			[Gtk::Stock::OK, Gtk::Dialog::RESPONSE_ACCEPT], [Gtk::Stock::CANCEL, Gtk::Dialog::RESPONSE_REJECT])
		self.title = title if title

		label = Gtk::Label.new(str)
		text  = Gtk::TextView.new

		text.signal_connect('key_press_event') { |w, ev|
			case ev.keyval
			when Gdk::Keyval::GDK_Escape; response(RESPONSE_REJECT) ; true
			when Gdk::Keyval::GDK_Return, Gdk::Keyval::GDK_KP_Enter; response(RESPONSE_ACCEPT) ; true
			end
		}

		signal_connect('response') { |win, id|
			if id == RESPONSE_ACCEPT
				text = text.buffer.text
				destroy
				yield text
			else
				destroy
			end
			true
		}

		vbox.pack_start label, false, false, 8
		vbox.pack_start text, false, false, 8

		show_all
		present
	end
end

class OpenFile < Gtk::FileChooserDialog
	# shows an asynchronous FileChooser window, yields the chosen filename
	# TODO save last path
	def initialize(owner, title)
		owner ||= Gtk::Window.toplevels.first
		super(title, owner, Gtk::FileChooser::ACTION_OPEN, nil,
		[Gtk::Stock::CANCEL, Gtk::Dialog::RESPONSE_CANCEL], [Gtk::Stock::OPEN, Gtk::Dialog::RESPONSE_ACCEPT])
		signal_connect('response') { |win, id|
			if id == Gtk::Dialog::RESPONSE_ACCEPT
				file = filename
			end
			destroy
			yield file if file
			true
		}

		show_all
		present
	end
end

class SaveFile < Gtk::FileChooserDialog
	# shows an asynchronous FileChooser window, yields the chosen filename
	# TODO save last path
	def initialize(owner, title)
		owner ||= Gtk::Window.toplevels.first
		super(title, owner, Gtk::FileChooser::ACTION_SAVE, nil,
		[Gtk::Stock::CANCEL, Gtk::Dialog::RESPONSE_CANCEL], [Gtk::Stock::SAVE, Gtk::Dialog::RESPONSE_ACCEPT])
		signal_connect('response') { |win, id|
			if id == Gtk::Dialog::RESPONSE_ACCEPT
				file = filename
			end
			destroy
			yield file if file
			true
		}

		show_all
		present
	end
end

class ListWindow < Gtk::Dialog
	# shows a window with a list of items
	# the list is an array of arrays, displayed as String
	# the first array is the column names
	# each item double-clicked yields the block with the selected iterator
	def initialize(owner, title, list)
		# TODO clickable column headers
		owner ||= Gtk::Window.toplevels.first
		super(title, owner, Gtk::Dialog::DESTROY_WITH_PARENT)

		cols = list.shift

		treeview = Gtk::TreeView.new
		treeview.model = Gtk::ListStore.new(*[String]*cols.length)
		treeview.selection.mode = Gtk::SELECTION_NONE

		cols.each_with_index { |col, i|
			crt = Gtk::CellRendererText.new
			tvc = Gtk::TreeViewColumn.new(col, crt)
			tvc.set_cell_data_func(crt) { |_tvc, _crt, model, iter| _crt.text = iter[i] }
			treeview.append_column tvc
		}

		list.each { |e|
			iter = treeview.model.append
			e.each_with_index { |v, i| iter[i] = v.to_s }
		}

		treeview.model.set_sort_column_id(0)

		treeview.signal_connect('cursor_changed') { |x|
			if iter = treeview.selection.selected
				yield iter
			end
		}

		remove vbox
		add Gtk::ScrolledWindow.new.add(treeview)
		toplevel.set_default_size cols.length*120, 400

		show_all
		present

		# so that the 1st line is not selected by default
		treeview.selection.mode = Gtk::SELECTION_SINGLE
	end
end

class MainWindow < Gtk::Window
	attr_accessor :dasm_widget, :menu
	def initialize(title = 'metasm disassembler')
		super()

		(@@mainwindow_list ||= []) << self
		signal_connect('destroy') {
			# TODO kill all my popups
			@@mainwindow_list.delete self
			Gtk.main_quit if @@mainwindow_list.empty?
		}

		self.title = title
		@dasm_widget = nil
		build_menu
		@vbox = Gtk::VBox.new
		add @vbox
		@vbox.add @menu, 'expand' => false
		set_default_size 700, 600
	end

	def display(dasm, ep=[])
		if @dasm_widget
			@dasm_widget.terminate
			@vbox.remove @dasm_widget
		end
		@dasm_widget = DisasmWidget.new(dasm, ep)
		@vbox.add @dasm_widget
		show_all
	end

	def build_menu
		@menu = Gtk::MenuBar.new
		filemenu = Gtk::Menu.new

		addsubmenu(filemenu, 'open') {
			OpenFile.new(self, 'chose target binary') { |exename|
				exe = Metasm::AutoExe.orshellcode(Metasm::Ia32.new).decode_file(exename)
				(@dasm_widget ? MainWindow.new : self).display(exe.init_disassembler)
			}
		}

		addsubmenu(filemenu, 'open live') {
			InputBox.new(self, 'chose target') { |target|
				if not target = Metasm::OS.current.find_process(target)
					MessageBox.new(self, 'no such target')
				else
					exe = Metasm::Shellcode.decode(target.memory, Metasm::Ia32.new)
					(@dasm_widget ? MainWindow.new : self).display(exe.init_disassembler)
				end
			}
		}

		addsubmenu(filemenu, 'close') {
			if @dasm_widget
				@dasm_widget.terminate
				@vbox.remove @dasm_widget
				@dasm_widget = nil
			end
		}

		if false
			# TODO patch Dasm
		addsubmenu(filemenu, 'save map') {
			SaveFile.new(self, 'chose map file') { |file|
				File.open(file, 'w') { |fd|
					fd.puts @dasm_widget.dasm.save_map
				} if @dasm_widget
			} if @dasm_widget
		}
		addsubmenu(filemenu, 'load map') {
			OpenFile.new(self, 'chose map file') { |file|
				@dasm_widget.dasm.load_map(File.read(file)) if @dasm_widget
			} if @dasm_widget
		}
		end

		addsubmenu(filemenu, 'save C') {
			SaveFile.new(self, 'chose C file') { |file|
				File.open(file, 'w') { |fd|
					fd.puts @dasm_widget.dasm.c_parser
				} if @dasm_widget
			} if @dasm_widget
		}
		addsubmenu(filemenu, 'load C') {
			OpenFile.new(self, 'chose C file') { |file|
				@dasm_widget.dasm.parse_c(File.read(file)) if @dasm_widget
			} if @dasm_widget
		}
		# 'reset C' ?

		# TODO save (map + comments + ...)

		addsubmenu(filemenu, 'exit') { destroy } # post_quit_message ?

		filemenu_i = Gtk::MenuItem.new('file')
		filemenu_i.set_submenu filemenu
		@menu.append filemenu_i

		# 'run ruby code'
		# 'load ruby plugin'
		# 'list functions'
		# 'list labels'
		# 'start dasm here'
		# options -> maxbacktrace(_data), change CPU..
		# factorize headers
	end

	def addsubmenu(menu, name, &action)
		item = Gtk::MenuItem.new(name)
		item.signal_connect('activate') { protect { action.call } }
		menu.append item
	end

	def protect
		begin
			yield
		rescue Object
			MessageBox.new(self, $!.message, $!.class)
		end
	end
end

end
end
