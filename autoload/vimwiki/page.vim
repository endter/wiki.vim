" vimwiki
"
" Maintainer: Karl Yngve Lervåg
" Email:      karl.yngve@gmail.com
"

function! vimwiki#page#delete() "{{{1
  let l:input_response = input('Delete "' . expand('%') . '" [y]es/[N]o? ')
  if l:input_response !~? '^y' | return | endif

  let l:filename = expand('%:p')
  try
    call delete(l:filename)
  catch /.*/
    echomsg 'Vimwiki Error: Cannot delete "' . expand('%:t:r') . '"!'
    return
  endtry

  call vimwiki#nav#return()
  execute 'bdelete! ' . escape(l:filename, " ")
endfunction

"}}}1
function! vimwiki#page#rename() "{{{1
  " Check if current file exists
  if !filereadable(expand('%:p'))
    echom 'Vimwiki Error: Cannot rename "' . expand('%:p')
          \ . '". It does not exist! (New file? Save it before renaming.)'
    return
  endif

  if b:vimwiki.in_diary
    echom 'Not supported yet.'
    return
  endif

  " Ask if user wants to rename
  if input('Rename "' . expand('%:t:r') . '" [y]es/[N]o? ') !~? '^y'
    return
  endif

  " Get new page name
  let l:new = {}
  let l:new.name = substitute(input('Enter new name: '), '\.wiki$', '', '')
  echon "\r"
  if empty(substitute(l:new.name, '\s*', '', ''))
    echom 'Vimwiki Error: Cannot rename to an empty filename!'
    return
  endif

  " Expand to full path name, check if already exists
  let l:new.path = expand('%:p:h') . '/' . l:new.name . '.wiki'
  if filereadable(l:new.path)
    echom 'Vimwiki Error: Cannot rename to "' . l:new.path
          \ . '". File with that name exist!'
    return
  endif

  " Rename current file to l:new.path
  try
    echom 'Vimwiki: Renaming ' . expand('%:t')
          \ . ' to ' . fnamemodify(l:new.path, ':t')
    if rename(expand('%:p'), l:new.path) != 0
      throw 'Cannot rename!'
    end
    setlocal buftype=nofile
  catch
    echom 'Vimwiki Error: Cannot rename "'
          \ . expand('%:t:r') . '" to "' . l:new.path . '"!'
    return
  endtry

  " Store some info from old buffer
  let l:old = {
        \ 'path' : expand('%:p'),
        \ 'name' : expand('%:t:r'),
        \ 'prev_link' : get(b:, 'vimwiki_prev_link', ''),
        \}

  " Get list of open wiki buffers
  let l:bufs = map(filter(map(filter(range(1, bufnr('$')),
        \       'bufexists(v:val)'),
        \     'fnamemodify(bufname(v:val), '':p'')'),
        \   'v:val =~# ''.wiki$'''),
        \ '[v:val, getbufvar(v:val, ''vimwiki.prev_link'')]')

  " Save and close wiki buffers
  for [l:bufname, l:dummy] in l:bufs
    execute 'b' fnameescape(l:bufname)
    update
    execute 'bwipeout' fnameescape(l:bufname)
  endfor

  " Update links
  call s:rename_update_links(l:old.name, l:new.name)

  " Restore wiki buffers
  for [l:bufname, l:prev_link] in l:bufs
    if resolve(l:bufname) ==# resolve(l:old.path)
      call s:rename_open_buffer(l:new.path, l:old.prev_link)
    else
      call s:rename_open_buffer(l:bufname, l:prev_link)
    endif
  endfor
endfunction

" }}}1
function! vimwiki#page#get_links(...) "{{{1
  let l:file = a:0 > 0 ? a:1 : expand('%')
  if !filereadable(l:file) | return [] | endif

  " TODO: Should match more types of links
  let l:regex = g:vimwiki.link_matcher.wiki.rx_url

  let l:links = []
  let l:lnum = 0
  for l:line in readfile(l:file)
    let l:lnum += 1
    let l:count = 0
    while 1
      let l:count += 1
      let l:col = match(l:line, l:regex, 0, l:count)+1
      if l:col <= 0 | break | endif

      let l:link = extend(
            \ vimwiki#link#parse(
            \   matchstr(l:line, l:regex, 0, l:count),
            \   { 'origin' : l:file }),
            \ { 'lnum' : l:lnum, 'col' : l:col })

      if has_key(l:link, 'filename')
        call add(l:links, l:link)
      endif
    endwhile
  endfor

  return l:links
endfunction

"}}}1

function! s:rename_open_buffer(fname, prev_link) " {{{1
  let l:opts = {}
  if !empty(a:prev_link)
    let l:opts.prev_link = a:prev_link
  endif

  silent! call vimwiki#edit_file(a:fname, l:opts)
endfunction

" }}}1
function! s:rename_update_links(old, new) " {{{1
  let l:pattern  = '\v\[\[\/?\zs' . a:old . '\ze%(#.*)?%(|.*)?\]\]'
  let l:pattern .= '|\[.*\]\[\zs' . a:old . '\ze%(#.*)?\]'
  let l:pattern .= '|\[.*\]\(\zs' . a:old . '\ze%(#.*)?\)'
  let l:pattern .= '|\[\zs' . a:old . '\ze%(#.*)?\]\[\]'

  for l:file in glob(g:vimwiki.root . '**/*.wiki', 0, 1)
    let l:updates = 0
    let l:lines = []
    for l:line in readfile(l:file)
      if match(l:line, l:pattern) != -1
        let l:updates = 1
        call add(l:lines, substitute(l:line, l:pattern, a:new, 'g'))
      else
        call add(l:lines, l:line)
      endif
    endfor

    if l:updates
      echom 'Updating links in: ' . fnamemodify(l:file, ':t')
      call rename(l:file, l:file . '#tmp')
      call writefile(l:lines, l:file)
      call delete(l:file . '#tmp')
    endif
  endfor
endfunction

" }}}1

function! vimwiki#page#create_toc() " {{{1
  let l:winsave = winsaveview()
  let l:syntax = &l:syntax
  setlocal syntax=off

  let l:start = 1
  let l:entries = []
  let l:anchor_stack = []
  let l:link = split(g:vimwiki.link_matcher.wiki.template[1], '\v__(Url|Text)__')

  "
  " Create toc entries
  "
  for l:lnum in range(1, line('$'))
    if vimwiki#u#is_code(l:lnum) | continue | endif

    " Get line - check for header
    let l:line = getline(l:lnum)
    if l:line !~# g:vimwiki.rx.header | continue | endif

    " Parse current header
    let l:level = len(matchstr(l:line, '^#*'))
    let l:header = matchlist(l:line, g:vimwiki.rx.header_items)[2]
    if l:header ==# 'Innhald' | continue | endif

    " Update header stack in order to have well defined anchor
    let l:depth = len(l:anchor_stack)
    if l:depth >= l:level
      call remove(l:anchor_stack, l:level-1, l:depth-1)
    endif
    call add(l:anchor_stack, l:header)
    let l:anchor = '#' . join(l:anchor_stack, '#')

    " Add current entry
    call add(l:entries, repeat(' ', shiftwidth()*(l:level-1)) . '- '
          \ . l:link[0] . l:anchor . l:link[1] . l:header . l:link[2])
  endfor

  "
  " Delete TOC if it exists
  "
  for l:lnum in range(1, line('$'))
    if getline(l:lnum) =~# '^\s*#[^#]\+Innhald'
      let l:start = l:lnum
      let l:end = l:start + (getline(l:lnum+1) =~# '^\s*$' ? 2 : 1)
      while l:end <= line('$') && getline(l:end) =~# '^\s*- '
        let l:end += 1
      endwhile

      let l:foldenable = &l:foldenable
      setlocal nofoldenable
      silent execute printf('%d,%ddelete _', l:start, l:end - 1)
      let &l:foldenable = l:foldenable

      break
    endif
  endfor

  "
  " Add updated TOC
  "
  call append(l:start - 1, '# Innhald')
  let l:length = len(l:entries)
  for l:i in range(l:length)
    call append(l:start + l:i, l:entries[l:i])
  endfor
  if getline(l:start + l:length + 1) !=# ''
    call append(l:start + l:length, '')
  endif
  call append(l:start, '')

  "
  " Restore view
  "
  let &l:syntax = l:syntax
  call winrestview(l:winsave)
endfunction

" }}}1

" vim: fdm=marker sw=2

