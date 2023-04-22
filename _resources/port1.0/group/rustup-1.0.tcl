# -*- coding: utf-8; mode: tcl; c-basic-offset: 4; indent-tabs-mode: nil; tab-width: 4; truncate-lines: t -*- vim:fenc=utf-8:et:sw=4:ts=4:sts=4
#
# Copyright (c) 2023 R.J.V. Bertin
# All rights reserved.
#
# Usage:
# PortGroup     rustup 1.1
#
# This PortGroup is for ports that require rust and/or cargo to be built
# but do not depend on it otherwise (port:clamav, for example). Rather than
# requiring the obligatory installation of port:rust and/or port:cargo,
# allow the port to use a temporary, private install from rustup.rs .

namespace eval rustup {
    # our directory:
    set currentportgroupdir [file dirname [dict get [info frame 0] file]]
    # ports may (have to) include us more than once
    if {![info exists includecounter]} {
        set includecounter  0
    }


    if {${includecounter} >= 1} {
        ui_debug "We don't include PG rustup more than once"
        return
    }

    proc use_rustup {} {
        return [expr [variant_exists rustup_build] && [variant_isset rustup_build]]
    }

    # should ports need to provide their own version of the RustUp install script;
    # without that, we will need the rust and/or cargo ports?
    # if {[file exists ${filespath}/rustup-install.sh]} {
        variant rustup_build conflicts no_rustup description {build this port using a private rust install from rustup.rs} {}
    #     variant no_rustup conflicts rustup_build description {force a build using port:rust and/or port:cargo} {}
        if {![variant_isset no_rustup] && \
                !([file exists ${prefix}/bin/rustc] && [file exists ${prefix}/bin/cargo])} {
            default_variants-append +rustup_build
            if {[variant_isset rustup_build]} {
                ui_debug "Build will use rustup by default"
            }
        }
    # }

    # The path where we install rustup.
    # NB NB: we need to access this variable via its namespace in
    # the post-X blocks below because they are not executed inside
    # our own namespace!
    set home    ${workpath}/.rustup
}

if {![rustup::use_rustup]} {
    PortGroup rust 1.0
} else {
    # too tricky to remove the port:rust and port:cargo deps
   # that are added by the rust PG so we don't include it...
    PortGroup openssl 1.0
    PortGroup compiler_wrapper 1.0
    if {${os.platform} eq "darwin"} {
        # for gmktemp:
        depends_build-append \
            port:coreutils
    }
    if {![info exists configure.ld]} {
        options configure.ld
        configure.ld        ${prefix}/bin/ld
        if {${os.platform} eq "darwin"} {
            depends_build-append port:ld64
        } else {
            depends_build-append port:binutils
        }
    }
    set env(RUSTUP_HOME)    ${rustup::home}
    set env(CARGO_HOME)     ${rustup::home}/Cargo
    # Rust does not easily pass external flags to compilers, so add them to compiler wrappers
    default compwrap.compilers_to_wrap          {cc cxx ld}
    default compwrap.ccache_supported_compilers {}
}
set env(PATH)               ${rustup::home}/Cargo/bin:$env(PATH)

namespace eval rustup {
    post-fetch {
        # There is no way to guarantee that the rustup install script will always be the same
        # and that snapshots will continue to work. Ports would thus have to provide a copy
        # in their $filespath and keep it up-to-date (hence the interrogation above).
        # curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs > $TMPDIR/install.sh
        if {![file exists ${rustup::home}/rustup-install.sh]} {
            xinstall -d ${rustup::home}
            curl fetch --remote-time --progress ui_progress_download \
                https://sh.rustup.rs \
                ${rustup::home}/rustup-install.sh
            platform darwin {
                reinplace "s|mktemp|gmktemp|g" ${rustup::home}/rustup-install.sh
            }
            file attributes ${rustup::home}/rustup-install.sh -permissions ug+x
            platform linux {
                # the script downloads the rustup-init binary and installs it as
                # $CARGO_HOME/bin/rustup ; on my Linux this can generate an EAGAIN
                # error, apparently because I'm running ZFS. So, we download that
                # binary ourselves...
                ui_debug "Downloading the rustup installer binary directly"
                xinstall -d ${rustup::home}/Cargo/bin/
                curl fetch --progress ui_progress_download \
                    https://static.rust-lang.org/rustup/dist/[exec uname -m]-unknown-linux-gnu/rustup-init \
                    ${rustup::home}/Cargo/bin/rustup
                file attributes ${rustup::home}/Cargo/bin/rustup -permissions ug+x
            }
        }
    }

    pre-extract {
        if {[rustup::use_rustup] && ![file exists ${rustup::home}/Cargo/bin/cargo]} {
            ui_msg "--->  Doing rustup install"
            if {[file exists ${rustup::home}/Cargo/bin/rustup]} {
                system "${rustup::home}/Cargo/bin/rustup set profile minimal"
                system "${rustup::home}/Cargo/bin/rustup install stable"
            } else {
                system "${rustup::home}/rustup-install.sh --profile minimal --no-modify-path -y"
            }
        }
    }

    proc ccache-wrapper {pth comm} {
        if {![catch {set f [open "${pth}" "w"]} err]} {
            puts ${f} "#!/bin/sh\n"
            puts ${f} "exec ccache ${comm} \"$@\""
            close ${f}
            file attributes ${pth} -permissions ug+x
        } else {
            ui_error $::errorInfo
            return -code error "failed to create ccache wrapper ${pth} for ${comm}: ${err}"
        }
    }

    pre-configure {
        ui_debug "PATH=$env(PATH)"
        if {![rustup::use_rustup]} {
            xinstall -m 755 -d ${rustup::home}/Cargo/bin/
        }
        file delete -force \
            ${rustup::home}/Cargo/bin/cc \
            ${rustup::home}/Cargo/bin/c++ \
            ${rustup::home}/Cargo/bin/ld
        if {![tbool configure.ccache] && [tbool configureccache]} {
            # the cmake PG unsets configure.ccache but not configureccache; the
            # compwrap wrappers thus still need a ccache wrapper...
            rustup::ccache-wrapper ${rustup::home}/Cargo/bin/cc     [compwrap::wrap_compiler cc]
            rustup::ccache-wrapper ${rustup::home}/Cargo/bin/c++    [compwrap::wrap_compiler cxx]
        } else {
            ln -s [compwrap::wrap_compiler cc]  ${rustup::home}/Cargo/bin/cc
            ln -s [compwrap::wrap_compiler cxx] ${rustup::home}/Cargo/bin/c++
        }
        ln -s [compwrap::wrap_compiler ld]      ${rustup::home}/Cargo/bin/ld
    }

    pre-build {
        ui_debug "PATH=$env(PATH)"
    }

    set includecounter [expr ${includecounter} + 1]

}
