# fish completion for b2d

complete -c b2d -s o -l out -d 'target directory (default: .)' -r -a '(__fish_complete_directories)'
complete -c b2d -s n -l dry-run -d 'validate and print the plan; write nothing'
complete -c b2d -s v -l verbose -d 'print one line per entry while applying'
complete -c b2d -l no-clobber -d 'fail instead of replacing existing entries'
complete -c b2d -s h -l help -d 'print usage and exit'
complete -c b2d -s V -l version -d 'print version and exit'
complete -c b2d -d 'brainfuck file' -r -a '*.bf'
