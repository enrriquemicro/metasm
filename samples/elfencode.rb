#!/usr/bin/env ruby
#    This file is part of Metasm, the Ruby assembly manipulation suite
#    Copyright (C) 2007 Yoann GUILLOT
#
#    Licence is LGPL, see LICENCE in the top-level directory



require 'metasm'

elf = Metasm::ELF.assemble(Metasm::Ia32.new, DATA.read)
elf.encode_file('sampelf')

__END__
.interp '/lib/ld-linux.so.2'
.pt_gnu_stack rw

.data
toto db "world", 0
fmt db "Hello, %s !\n", 0

.text
.entrypoint
 call metasm_intern_geteip
 mov esi, eax
 lea eax, [esi-metasm_intern_geteip+toto]
 push eax
 lea eax, [esi-metasm_intern_geteip+fmt]
 push eax
 call printf
 add esp, 8

 push 28h
 call _exit
 add esp, 4
 ret

metasm_intern_geteip:
 call asonht
asonht:
 pop eax
 add eax, metasm_intern_geteip - asonht
 ret

