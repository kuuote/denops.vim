let s:SCRIPT = denops#_internal#path#script(['@denops-private', 'cli.ts'])

let s:job = v:null
let s:options = v:null
let s:stopped_on_purpose = 0
let s:exiting = 0

" Args:
"   options: {
"     retry_interval: number
"     retry_threshold: number
"     restart_on_exit: boolean
"     restart_delay: number
"     restart_interval: number
"     restart_threshold: number
"   }
" Return:
"   boolean
function! denops#_internal#server#proc#start(options) abort
  if s:job isnot# v:null
    throw '[denops] Server already exists'
  endif
  let l:retry_interval = a:options.retry_interval
  let l:retry_threshold = a:options.retry_threshold
  let l:previous_exception = ''
  for l:i in range(l:retry_threshold)
    call denops#_internal#echo#debug(printf(
          \ 'Spawn server [%d/%d]',
          \ l:i + 1,
          \ l:retry_threshold + 1,
          \))
    try
      call s:start(a:options)
      return v:true
    catch
      call denops#_internal#echo#debug(printf(
            \ 'Failed to spawn server [%d/%d]: %s',
            \ l:i + 1,
            \ l:retry_threshold + 1,
            \ v:exception,
            \))
      let l:previous_exception = v:exception
    endtry
    execute printf('sleep %dm', l:retry_interval)
  endfor
  call denops#_internal#echo#error(printf(
        \ 'Failed to spawn server: %s',
        \ l:previous_exception,
        \))
endfunction

function! denops#_internal#server#proc#stop() abort
  if s:job is# v:null
    throw '[denops] Server does not exist yet'
  endif
  let s:stopped_on_purpose = 1
  call denops#_internal#job#stop(s:job)
  let s:job = v:null
endfunction

function! denops#_internal#server#proc#is_started() abort
  return s:job isnot# v:null
endfunction

function! s:start(options) abort
  let l:args = [g:denops#deno, 'run']
  let l:args += g:denops#server#deno_args
  let l:args += [
        \ s:SCRIPT,
        \ '--quiet',
        \ '--identity',
        \ '--port', '0',
        \]
  let l:store = {'prepared': 0}
  let s:stopped_on_purpose = 0
  let s:job = denops#_internal#job#start(l:args, {
        \ 'env': {
        \   'NO_COLOR': 1,
        \   'DENO_NO_PROMPT': 1,
        \ },
        \ 'on_stdout': { _job, data, _event -> s:on_stdout(l:store, data) },
        \ 'on_stderr': { _job, data, _event -> s:on_stderr(data) },
        \ 'on_exit': { _job, status, _event -> s:on_exit(a:options, status) },
        \})
  let s:options = a:options
  call denops#_internal#echo#debug(printf('Server started: %s', l:args))
  doautocmd <nomodeline> User DenopsProcessStarted
endfunction

function! s:on_stdout(store, data) abort
  if a:store.prepared
    for l:line in split(a:data, '\n')
      echomsg printf('[denops] %s', substitute(l:line, '\t', '    ', 'g'))
    endfor
    return
  endif
  let a:store.prepared = 1
  let l:addr = substitute(a:data, '\r\?\n$', '', 'g')
  call denops#_internal#echo#debug(printf('Server listen: %s', l:addr))
  execute printf('doautocmd <nomodeline> User DenopsProcessListen:%s', l:addr)
endfunction

function! s:on_stderr(data) abort
  echohl ErrorMsg
  for l:line in split(a:data, '\n')
    echomsg printf('[denops] %s', substitute(l:line, '\t', '    ', 'g'))
  endfor
  echohl None
endfunction

function! s:on_exit(options, status) abort
  let s:job = v:null
  call denops#_internal#echo#debug(printf('Server stopped: %s', a:status))
  execute printf('doautocmd <nomodeline> User DenopsProcessStopped:%s', a:status)
  if !a:options.restart_on_exit || s:stopped_on_purpose || s:exiting
    return
  endif
  " Restart
  if s:restart_guard(a:options)
    return
  endif
  call denops#_internal#echo#warn(printf(
        \ 'Server stopped (%d). Restarting...',
        \ a:status,
        \))
  call timer_start(
        \ a:options.restart_delay,
        \ { -> denops#_internal#server#proc#start(s:options) },
        \)
endfunction

function! s:restart_guard(options) abort
  let l:restart_threshold = a:options.restart_threshold
  let l:restart_interval = a:options.restart_interval
  let s:restart_count = get(s:, 'restart_count', 0) + 1
  if s:restart_count >= l:restart_threshold
    call denops#_internal#echo#warn(printf(
          \ 'Server stopped %d times within %d millisec. Denops is disabled to avoid infinity restart loop.',
          \ l:restart_threshold,
          \ l:restart_interval,
          \))
    let g:denops#disabled = 1
    return 1
  endif
  if exists('s:reset_restart_count_delayer')
    call timer_stop(s:reset_restart_count_delayer)
  endif
  let s:reset_restart_count_delayer = timer_start(
        \ l:restart_interval,
        \ { -> extend(s:, { 'restart_count': 0 }) },
        \)
endfunction

augroup denops_internal_server_proc_internal
  autocmd!
  autocmd VimLeave * let s:exiting = 1
  autocmd User DenopsProcessStarted :
  autocmd User DenopsProcessListen:* :
  autocmd User DenopsProcessStopped:* :
augroup END
