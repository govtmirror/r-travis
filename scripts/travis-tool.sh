#!/bin/bash
# -*- sh-basic-offset: 4; sh-indentation: 4 -*-
# Bootstrap an R/travis environment.

set -e

CRAN=${CRAN:-"http://cran.rstudio.com"}
OS=$(uname -s)
if [ -n "${WINE}" -a "Linux" == ${OS} ]; then
    OS=Wine
fi

# MacTeX installs in a new $PATH entry, and there's no way to force
# the *parent* shell to source it from here. So we just manually add
# all the entries to a location we already know to be on $PATH.
#
# TODO(craigcitro): Remove this once we can add `/usr/texbin` to the
# root path.
PATH="${PATH}:/usr/texbin"

R_BUILD_ARGS=${R_BUILD_ARGS-"--no-build-vignettes"}
R_CHECK_ARGS=${R_CHECK_ARGS-"--no-manual --as-cran"}

CheckNoop() {
    if [ "Darwin" == "${OS}" ]; then
        if [ -n "${WINE}" ]; then
            return
        fi
    fi

    false
}

Bootstrap() {
    if [ "Darwin" == "${OS}" ]; then
        BootstrapMac
    elif [ "Linux" == "${OS}" ]; then
        BootstrapLinux
    elif [ "Wine" == "${OS}" ]; then
        BootstrapWine
    else
        echo "Unknown OS: ${OS}"
        exit 1
    fi

    if ! (test -e .Rbuildignore && grep -q 'travis-tool' .Rbuildignore); then
        echo '^travis-tool\.sh$' >>.Rbuildignore
    fi
}

BootstrapLinux() {
    # Set up our CRAN mirror.
    sudo add-apt-repository "deb ${CRAN}/bin/linux/ubuntu $(lsb_release -cs)/"
    sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys E084DAB9

    # Add marutter's c2d4u repository.
    sudo add-apt-repository -y "ppa:marutter/rrutter"
    sudo add-apt-repository -y "ppa:marutter/c2d4u"

    # Update after adding all repositories.
    sudo apt-get update -qq

    # Install an R development environment. qpdf is also needed for
    # --as-cran checks:
    #   https://stat.ethz.ch/pipermail/r-help//2012-September/335676.html
    sudo apt-get install r-base-dev qpdf

    # Change permissions for /usr/local/lib/R/site-library
    # This should really be via 'staff adduser travis staff'
    # but that may affect only the next shell
    sudo chmod 2777 /usr/local/lib/R /usr/local/lib/R/site-library

    # Process options
    BootstrapLinuxOptions
}

BootstrapLinuxOptions() {
    if [ -n "$BOOTSTRAP_LATEX" ]; then
        sudo apt-get install --no-install-recommends \
            texlive-base texlive-latex-base texlive-generic-recommended \
            texlive-fonts-recommended texlive-fonts-extra \
            texlive-extra-utils texlive-latex-recommended texlive-latex-extra \
            texinfo lmodern
    fi
}

BootstrapMac() {
    # Install from latest CRAN binary build for OS X
    wget ${CRAN}/bin/macosx/R-latest.pkg  -O /tmp/R-latest.pkg

    echo "Installing OS X binary package for R"
    sudo installer -pkg "/tmp/R-latest.pkg" -target /
    rm "/tmp/R-latest.pkg"

    # Process options
    BootstrapMacOptions
}

BootstrapMacOptions() {
    if [[ -n "$BOOTSTRAP_LATEX" ]]; then
        # TODO: Install MacTeX.pkg once there's enough disk space
        MACTEX=mactex-basic.pkg
        wget http://ctan.math.utah.edu/ctan/tex-archive/systems/mac/mactex/$MACTEX -O "/tmp/$MACTEX"

        echo "Installing OS X binary package for MacTeX"
        sudo installer -pkg "/tmp/$MACTEX" -target /
        rm "/tmp/$MACTEX"
        # We need a few more packages than the basic package provides; this
        # post saved me so much pain:
        #   https://stat.ethz.ch/pipermail/r-sig-mac/2010-May/007399.html
        sudo tlmgr update --self
        sudo tlmgr install inconsolata upquote courier courier-scaled helvetic
    fi
}

BootstrapWine() {
    # Start xvfb.
    sh -e /etc/init.d/xvfb start

    # Set up Wine PPA.
    sudo apt-add-repository -y ppa:ubuntu-wine/ppa

    # Update after adding all repositories.
    sudo apt-get update -qq

    # Install Wine.
    sudo apt-get install -q -y wine

    # Initialize Wine.
    wineboot

    # Download R.
    R_FILENAME=$(wget ${CRAN}/bin/windows/base/release.htm -O - |
        sed -n -r '/CONTENT="0; URL=.*\.exe"/{s/^.*URL=(.*)">.*$/\1/;p}')
    wget ${CRAN}/bin/windows/base/${R_FILENAME} -O /tmp/${R_FILENAME}

    # Install R.
    wine /tmp/${R_FILENAME} /silent
    rm /tmp/${R_FILENAME}
    R_HOME=$(echo "$HOME/.wine/drive_c/Program Files/R/"R-*/bin/x64)

    # Create R and Rscript scripts
    for EXE in R Rscript; do
        ( echo '#!/bin/sh';
          echo 'wine "'"${R_HOME}/${EXE}.exe"'" "$@"' ) |
          sudo tee /usr/local/bin/${EXE}
        sudo chmod +x /usr/local/bin/${EXE}
    done

    # Download Rtools.
    # TODO: Figure out latest path automatically
    RTOOLS_FILENAME=Rtools31.exe
    wget ${CRAN}/bin/windows/Rtools/${RTOOLS_FILENAME} -O /tmp/${RTOOLS_FILENAME}

    # Install Rtools.
    unix2dos > /tmp/rtools.inf << "END_CAT"
[Setup]
Tasks=setpath,recordversion
END_CAT
    wine /tmp/${RTOOLS_FILENAME} /silent /loadinf=/tmp/rtools.inf
    rm /tmp/${RTOOLS_FILENAME}

    # Process options
    BootstrapWineOptions
}

BootstrapWineOptions() {
    if [ -n "$BOOTSTRAP_LATEX" ]; then
        echo "LaTeX currently not supported on Wine."
        exit 1
    fi
}

EnsureDevtools() {
    if ! Rscript -e 'if (!("devtools" %in% rownames(installed.packages()))) q(status=1)' ; then
        # Install devtools and testthat.
        if [ "Linux" == "${OS}" ]; then
            RBinaryInstall devtools testthat
        else
            RInstall devtools testthat
        fi
        # Bootstrap devtools to the live version on github.
        Rscript -e 'library(devtools); library(methods); install_github("devtools", args=list(INSTALL_args="--no-multiarch")'
    fi
}

AptGetInstall() {
    if [ "Linux" != "${OS}" ]; then
        echo "Wrong OS: ${OS}"
        exit 1
    fi

    if [ "" == "$*" ]; then
        echo "No arguments to aptget_install"
        exit 1
    fi

    echo "Installing apt package(s) $*"
    sudo apt-get install $*
}

RInstall() {
    if [ "" == "$*" ]; then
        echo "No arguments to r_install"
        exit 1
    fi

    echo "Installing R package(s): ${pkg}"
    Rscript -e 'install.packages(commandArgs(TRUE), repos="'"${CRAN}"'")' $*
}

RBinaryInstall() {
    if [ "Linux" != "${OS}" ]; then
        echo "Wrong OS: ${OS}"
        exit 1
    fi

    if [[ -z "$#" ]]; then
        echo "No arguments to r_binary_install"
        exit 1
    fi

    echo "Installing *binary* R packages: $*"
    r_packages=$(echo $* | tr '[:upper:]' '[:lower:]')
    r_debs=$(for r_package in ${r_packages}; do echo -n "r-cran-${r_package} "; done)

    sudo apt-get install ${r_debs}
}

GithubPackage() {
    # An embarrassingly awful script for calling install_github from a
    # .travis.yml.
    #
    # Note that bash quoting makes this annoying for any additional
    # arguments.

    EnsureDevtools

    # Get the package name and strip it
    PACKAGE_NAME=$1
    shift

    # Join the remaining args.
    ARGS=$(echo $* | sed -e 's/ /, /g')
    if [ -n "${ARGS}" ]; then
        ARGS=", ${ARGS}"
    fi

    echo "Installing github package: ${PACKAGE_NAME}"
    # Install the package.
    Rscript -e 'library(devtools); library(methods); options(repos=c(CRAN="'"${CRAN}"'")); install_github("'"${PACKAGE_NAME}"'"'"${ARGS}"')'
}

InstallDeps() {
    EnsureDevtools
    Rscript -e 'library(devtools); library(methods); options(repos=c(CRAN="'"${CRAN}"'")); devtools:::install_deps(dependencies = TRUE)'
}

DumpSysinfo() {
    echo "Dumping system information."
    R -e '.libPaths(); sessionInfo(); installed.packages()'
}

DumpLogsByExtension() {
    if [[ -z "$1" ]]; then
        echo "dump_logs_by_extension requires exactly one argument, got: $*"
        exit 1
    fi
    extension=$1
    shift
    package=$(find . -name *Rcheck -type d)
    if [[ ${#package[@]} -ne 1 ]]; then
        echo "Could not find package Rcheck directory, skipping log dump."
        exit 0
    fi
    for name in $(find "${package}" -type f -name "*${extension}"); do
        echo ">>> Filename: ${name} <<<"
        cat ${name}
    done
}

DumpLogs() {
    echo "Dumping test execution logs."
    DumpLogsByExtension "out"
    DumpLogsByExtension "log"
    DumpLogsByExtension "fail"
}

RunTests() {
    echo "Building with: R CMD build ${R_BUILD_ARGS}"
    R CMD build ${R_BUILD_ARGS} .
    FILE=$(ls -1 *.tar.gz)

    echo "Testing with: R CMD check \"${FILE}\" ${R_CHECK_ARGS}"
    R CMD check "${FILE}" ${R_CHECK_ARGS}
}

# Don't do anything in no-op case
if CheckNoop; then
    exit 0
fi

COMMAND=$1
echo "Running command: ${COMMAND}"
shift
case $COMMAND in
    "check_noop")
        # We passed CheckNoop before, so it's not a no-op here
        exit 1
        ;;
    "bootstrap")
        Bootstrap
        ;;
    "devtools_install")
        EnsureDevtools
        ;;
    "aptget_install")
        AptGetInstall "$*"
        ;;
    "r_install")
        RInstall "$*"
        ;;
    "r_binary_install")
        RBinaryInstall "$*"
        ;;
    "github_package")
        GithubPackage "$*"
        ;;
    "install_deps")
        InstallDeps
        ;;
    "run_tests")
        RunTests
        ;;
    "dump_sysinfo")
        DumpSysinfo
        ;;
    "dump_logs")
        DumpLogs
        ;;
    "dump_logs_by_extension")
        DumpLogsByExtension "$*"
        ;;
esac
