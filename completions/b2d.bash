# bash completion for b2d

_b2d() {
    local cur prev opts
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="-o --out -n --dry-run -v --verbose --no-clobber -h --help -V --version"

    case "${prev}" in
        -o | --out)
            COMPREPLY=($(compgen -d -- "${cur}"))
            return 0
            ;;
    esac

    if [[ "${cur}" == -* ]]; then
        COMPREPLY=($(compgen -W "${opts}" -- "${cur}"))
        return 0
    fi

    COMPREPLY=($(compgen -f -X '!*.bf' -- "${cur}"))
}
complete -F _b2d b2d
