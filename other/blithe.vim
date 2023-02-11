" Vim syntax file
" Language: Blithe Lang
" Maintainer: Sean Carey
" Latest Revision: 20 August 2022

" See: /usr/share/nvim/runtime/syntax/python.vim
if exists("b:current_syntax")
  finish
endif

syn keyword basicLanguageKeywords PRINT OPEN IF

" Regions
syn region syntaxElementRegion start='x' end='y'

