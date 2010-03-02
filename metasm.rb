#    This file is part of Metasm, the Ruby assembly manipulation suite
#    Copyright (C) 2006-2009 Yoann GUILLOT
#
#    Licence is LGPL, see LICENCE in the top-level directory


module Metasm
	# root directory for metasm files
	# used by some scripts, eg to find samples/dasm-plugin directory
	Metasmdir = File.dirname(__FILE__)

	# constant defined in the same file as another
	Const_autorequire_equiv = {
		'X86' => 'Ia32', 'PPC' => 'PowerPC',
		'X64' => 'X86_64', 'AMD64' => 'X86_64',
		'UniversalBinary' => 'MachO', 'COFFArchive' => 'COFF',
		'PTrace' => 'LinOS', 'GNUExports' => 'LinOS',
		'LoadedELF' => 'ELF', 'LoadedPE' => 'PE',
		'LinuxRemoteString' => 'LinOS',
		'WinAPI' => 'WinOS', 'WindowsExports' => 'WinOS',
		'WindowsRemoteString' => 'WinOS', 'WinDbgAPI' => 'WinOS',
		'WinDebugger' => 'WinOS',
		'VirtualFile' => 'OS', 'VirtualString' => 'OS',
		'GdbRemoteString' => 'GdbClient', 'GdbRemoteDebugger' => 'GdbClient',
	}

	Const_autorequire = {
		'CPU' => ['encode', 'decode', 'render', 'main', 'exe_format/main', 'os/main'],
		'Ia32' => 'ia32', 'MIPS' => 'mips', 'PowerPC' => 'ppc',
		'X86_64' => 'x86_64', 'Sh4' => 'sh4',
		'C' => ['parse_c', 'compile_c'],
		'MZ' => 'exe_format/mz', 'PE' => 'exe_format/pe',
		'ELF' => ['exe_format/elf_encode', 'exe_format/elf_decode'],
		'COFF' => ['exe_format/coff_encode', 'exe_format/coff_decode'],
		'Shellcode' => 'exe_format/shellcode', 'AutoExe' => 'exe_format/autoexe',
		'AOut' => 'exe_format/a_out', 'MachO' => 'exe_format/macho',
		'NDS' => 'exe_format/nds', 'XCoff' => 'exe_format/xcoff',
		'Bflt' => 'exe_format/bflt',
		'Gui' => 'gui',
		'LinOS' => 'os/linux', 'WinOS' => 'os/windows',
		'GdbClient' => 'os/remote',
		'Decompiler' => 'decompile',
		'DynLdr' => 'dynldr',
	}

def self.const_missing(c)
	cst = Const_autorequire_equiv[c.to_s] || c.to_s

	files = Const_autorequire[cst]
	return if not files
	files = [files] if files.kind_of? ::String

	files.each { |f| require ::File.join('metasm', f) }

	const_get c
end

def self.require(f)
	# temporarily put the current file directory in the ruby include path
	if not $:.include? Metasmdir
		incdir = Metasmdir
		$: << incdir
	end

	super(f)

	$:.delete incdir if incdir
end
end

# handle subclasses, nested modules etc (e.g. Metasm::PE, to avoid Metasm::PE::Ia32: const not found)
class Module
alias premetasm_const_missing const_missing
def const_missing(c)
	# Object.const_missing => Module#const_missing and not the other way around
	# XXX should use Module.nesting, but ruby sucks arse
	# e.g. module Metasm ; module Bla ; class << self ; Ia32 ; end ; end ; end -> fail
	if (name =~ /^Metasm(::|$)/ or ancestors.include? Metasm) and cst = Metasm.const_missing(c)
		cst
	else
		premetasm_const_missing(c)
	end
end
end

# load core files by default (too many classes to check for otherwise)
Metasm::CPU.class

# remove an 1.9 warning, couldn't find a compatible way...
if {}.respond_to? :key
	puts "using ruby1.9 workaround for Hash.index" if $DEBUG
	class Hash ; alias index key end
end
