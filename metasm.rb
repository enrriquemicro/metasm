#    This file is part of Metasm, the Ruby assembly manipulation suite
#    Copyright (C) 2007 Yoann GUILLOT
#
#    Licence is LGPL, see LICENCE in the top-level directory


Metasmdir = File.dirname(__FILE__)

module Metasm
def self.const_missing(c)
	# constant defined in the same file as another
	cst = {
		'X86' => 'Ia32', 'PPC' => 'PowerPC',
		'X64' => 'X86_64',
		'UniversalBinary' => 'MachO', 'COFFArchive' => 'COFF',
		'PTrace32' => 'LinOS', 'GNUExports' => 'LinOS',
		'LoadedELF' => 'ELF', 'LoadedPE' => 'PE',
		'LinuxRemoteString' => 'LinOS',
		'WinAPI' => 'WinOS', 'WindowsExports' => 'WinOS',
		'WindowsRemoteString' => 'WinOS', 'WinDbg' => 'WinOS',
		'VirtualFile' => 'OS', 'VirtualString' => 'OS',
	}[c.to_s] || c.to_s

	files = {
		'Ia32' => 'ia32', 'MIPS' => 'mips', 'PowerPC' => 'ppc',
		'X86_64' => 'x86_64',
		'C' => ['parse_c', 'compile_c'],
		'MZ' => 'exe_format/mz', 'PE' => 'exe_format/pe',
		'ELF' => ['exe_format/elf_encode', 'exe_format/elf_decode'],
		'COFF' => ['exe_format/coff_encode', 'exe_format/coff_decode'],
		'Shellcode' => 'exe_format/shellcode', 'AutoExe' => 'exe_format/autoexe',
		'AOut' => 'exe_format/a_out', 'MachO' => 'exe_format/macho',
		'NDS' => 'exe_format/nds', 'XCoff' => 'exe_format/xcoff',
		'Bflt' => 'exe_format/bflt',
		'GtkGui' => 'gui/gtk',
		'LinOS' => 'os/linux', 'WinOS' => 'os/windows',
		'Decompiler' => 'decompile',
	}[cst]

	return if not files

	files = [files] if files.kind_of? ::String

	#puts "autorequire #{files.join(', ')}"
	files.each { |f| require File.join('metasm', f) }

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
	if (name =~ /^Metasm(::|$)/ or ancestors.include? Metasm) and cst = Metasm.const_missing(c)
		cst
	else
		premetasm_const_missing(c)
	end
end
end

# load core files by default (too many classes to check for otherwise)
Metasm.require 'metasm/encode'
Metasm.require 'metasm/decode'
Metasm.require 'metasm/render'
Metasm.require 'metasm/main'
Metasm.require 'metasm/exe_format/main'
Metasm.require 'metasm/os/main'


# remove an 1.9 warning, couldn't find a compatible way...
if {}.respond_to? :key
	puts "using ruby1.9 workaround for Hash.index" if $VERBOSE
	class Hash ; alias index key end
end
