#!/bin/bash
#
# Translate, compile, and run mycpp examples.
#
# TODO: Extract setup.sh, test.sh, and run.sh from this file.
#
# Usage:
#   ./run.sh <function name>
#
# Setup:
#
#   Clone mypy into $MYPY_REPO, and then:
#
#   Switch to the release-0.670 branch.  As of April 2019, that's the latest
#   release, and what I tested against.
#
#   Then install typeshed:
#
#   $ git submodule init
#   $ git submodule update
#
# If you don't have Python 3.6, then build one from a source tarball and then
# install it.  (NOTE: mypyc tests require the libsqlite3-dev dependency.  
# It's probably not necessary for running mycpp.)
# 
# Afterwards, these commands should work:
#
#   ./run.sh create-venv
#   source _tmp/mycpp-venv/bin/activate
#   ./run.sh mypy-deps      # install deps in virtual env
#   ./run.sh build-all      # translate and compile all examples
#   ./run.sh test-all       # check for correctness
#   ./run.sh benchmark-all  # compare speed

set -o nounset
set -o pipefail
set -o errexit

readonly THIS_DIR=$(cd $(dirname $0) && pwd)
readonly REPO_ROOT=$(cd $THIS_DIR/.. && pwd)

readonly MYPY_REPO=~/git/languages/mypy

source $REPO_ROOT/test/common.sh  # for R_PATH

banner() {
  echo -----
  echo "$@"
  echo -----
}

time-tsv() {
  $REPO_ROOT/benchmarks/time.py --tsv "$@"
}

create-venv() {
  local dir=_tmp/mycpp-venv
  /usr/local/bin/python3.6 -m venv $dir

  ls -l $dir
  
  echo "Now run . $dir/bin/activate"
}

# Do this inside the virtualenv
mypy-deps() {
  python3 -m pip install -r $MYPY_REPO/test-requirements.txt
}

# MyPy doesn't have a configuration option for this!  It's always an env
# variable.
export MYPYPATH=~/git/oilshell/oil
# for running most examples
export PYTHONPATH=".:$REPO_ROOT/vendor"

# Damn it takes 4.5 seconds to analyze.
translate-osh-parse() {

  #local main=~/git/oilshell/oil/bin/oil.py

  # Have to get rid of strict optional?
  local main=~/git/oilshell/oil/bin/osh_parse.py
  time ./mycpp.py $main
}

# Has some hard-coded stuff
translate-ordered() {
  local name=$1
  local snippet=$2
  shift 2

  local raw=_gen/${name}_raw.cc
  local out=_gen/${name}.cc

  ( source _tmp/mycpp-venv/bin/activate
    time PYTHONPATH=$MYPY_REPO ./mycpp.py "$@" > $raw
  )

  {
    echo "$snippet"
    filter-cpp $name $raw 
  } > $out

  wc -l _gen/*
}

# NOTE: Needs 'asdl/run.sh gen-cpp-demo' first
translate-compile-typed-arith() {
  # tdop.py is a dependency.  How do we determine order?
  #
  # I guess we should put them in arbitrary order.  All .h first, and then all
  # .cc first.

  # NOTE: tdop.py doesn't translate because of the RE module!

  local srcs=( $PWD/../asdl/tdop.py $PWD/../asdl/typed_arith_parse.py )

  local name=typed_arith_parse
  translate-ordered $name '#include "typed_arith.asdl.h"' "${srcs[@]}"

  cc -o _bin/$name $CPPFLAGS \
    -I . -I ../_tmp \
    _gen/$name.cc runtime.cc \
    -lstdc++
}

filter-cpp() {
  local main_module=${1:-fib_iter}
  shift

  cat <<EOF
#include "runtime.h"

EOF

  cat "$@"

  cat <<EOF

int main(int argc, char **argv) {
  if (getenv("BENCHMARK")) {
    $main_module::run_benchmarks();
  } else {
    $main_module::run_tests();
  }
}
EOF
}

_translate-example() {
  local name=${1:-fib}
  local main="examples/$name.py"

  mkdir -p _gen

  local raw=_gen/${name}_raw.cc
  local out=_gen/${name}.cc

  # NOTE: mycpp has to be run in the virtualenv, as well as with a different
  # PYTHONPATH.
  ( source _tmp/mycpp-venv/bin/activate
    time PYTHONPATH=$MYPY_REPO ./mycpp.py $main > $raw
  )
  wc -l $raw

  local main_module=$(basename $main .py)
  filter-cpp $main_module $raw > $out

  wc -l _gen/*

  echo
  cat $out
}

translate-example() {
  local name=$1
  # Allow overriding the default.
  # translate-modules and compile-modules are DIFFERENT.
  if test "$(type -t translate-$name)" = "function"; then
    translate-$name
  else
    _translate-example $name
  fi
}

EXAMPLES=( $(cd examples && echo *.py) )
EXAMPLES=( "${EXAMPLES[@]//.py/}" )

asdl-gen() {
  PYTHONPATH="$REPO_ROOT:$REPO_ROOT/vendor" $REPO_ROOT/core/asdl_gen.py "$@"
}

# This is the one installed from PIP
#mypy() { ~/.local/bin/mypy "$@"; }

# Use repo in the virtualenv
mypy() {
  ( source _tmp/mycpp-venv/bin/activate
    PYTHONPATH=$MYPY_REPO python3 -m mypy "$@";
  )
}

# classes and ASDL
translate-parse() {
  translate-ordered parse '#include "expr.asdl.h"' \
    $REPO_ROOT/asdl/format.py examples/parse.py 
} 

# build ASDL schema and run it
run-python-parse() {
  mkdir -p _gen
  local out=_gen/expr_asdl.py
  touch _gen/__init__.py
  asdl-gen mypy examples/expr.asdl > $out

  mypy --py2 --strict examples/parse.py

  PYTHONPATH="$REPO_ROOT/mycpp:$REPO_ROOT/vendor:$REPO_ROOT" examples/parse.py
}

run-cc-parse() {
  mkdir -p _gen
  local out=_gen/expr.asdl.h
  asdl-gen cpp examples/expr.asdl > $out

  translate-parse
  # Now compile it
}


readonly PREPARE_DIR=$PWD/../_devbuild/cpython-full

# NOT USED
modules-deps() {
  local main_module=modules
  local prefix=_tmp/modules

  # This is very hacky but works.  We want the full list of files.
  local pythonpath="$PWD:$PWD/examples:$(cd $PWD/../vendor && pwd)"

  pushd examples
  mkdir -p _tmp
  ln -s -f -v ../../../build/app_deps.py _tmp

  PYTHONPATH=$pythonpath \
    $PREPARE_DIR/python -S _tmp/app_deps.py both $main_module $prefix

  popd

  egrep '/mycpp/.*\.py$' examples/_tmp/modules-cpython.txt \
    | egrep -v '__init__.py|runtime.py' \
    | awk '{print $1}' > _tmp/manifest.txt

  local raw=_gen/modules_raw.cc
  local out=_gen/modules.cc

  cat _tmp/manifest.txt | xargs ./mycpp.py > $raw

  filter-cpp modules $raw > $out
  wc -l $raw $out
}

translate-modules() {
  local raw=_gen/modules_raw.cc
  local out=_gen/modules.cc

  ( source _tmp/mycpp-venv/bin/activate
    PYTHONPATH=$MYPY_REPO ./mycpp.py \
      testpkg/module1.py testpkg/module2.py examples/modules.py > $raw
  )
  filter-cpp modules $raw > $out
  wc -l $raw $out
}

# fib_recursive(35) takes 72 ms without optimization, 20 ms with optimization.
# optimization doesn't do as much for cgi.  1M iterations goes from ~450ms to ~420ms.

# -O3 is faster than -O2 for fib, but let's use -O2 since it's "standard"?

CPPFLAGS='-O2 -std=c++11 '

_compile-example() { 
  local name=${1:-fib} #  name of output, and maybe input
  local src=${2:-_gen/$name.cc}

  # need -lstdc++ for operator new

  #local flags='-O0 -g'  # to debug crashes
  mkdir -p _bin
  cc -o _bin/$name $CPPFLAGS -I . \
    runtime.cc $src -lstdc++
}

compile-example() {
  local name=$1
  if test "$(type -t compile-$name)" = "function"; then
    compile-$name
  else
    _compile-example $name
  fi
}

# Because it depends on ASDL
compile-parse() {
  _compile-example parse '' -I _gen
}

run-python-example() {
  local name=$1
  examples/${name}.py
}

run-example() {
  local name=$1

  translate-example $name
  compile-example $name

  echo
  echo $'\t[ C++ ]'
  time _bin/$name

  echo
  echo $'\t[ Python ]'
  time examples/${name}.py
}

benchmark() {
  export BENCHMARK=1
  run-example "$@"
}

# NOTES on timings:

### fib_recursive
# fib_recursive(33) - 1083 ms -> 12 ms.  Biggest speedup!

### cgi
# 1M iterations: 580 ms -> 173 ms
# optimizations:
# - const_pass pulls immutable strings to top level
# - got rid of # function docstring!

### escape
# 200K iterations: 471 ms -> 333 ms

### cartesian
# 200K iterations: 800 ms -> 641 ms

### length
# no timings

### parse
# Good news!  Parsing is 10x faster.
# 198 ms in C++ vs 1,974 in Python!  Is that because of the method calls?
benchmark-parse() {
  export BENCHMARK=1

  local name=parse

  echo
  echo $'\t[ C++ ]'
  time _bin/$name

  # TODO: Consolidate this with the above.
  # We need 'asdl'
  export PYTHONPATH="$REPO_ROOT/mycpp:$REPO_ROOT"

  echo
  echo $'\t[ Python ]'
  time examples/${name}.py
}

should-skip() {
  case $1 in
    # not passing yet!
    # parse needs asdl/format.py, and the other 3 are testing features it
    # uses.
    parse|files|classes)
      return 0
      ;;
    *)
      return 1
  esac
}


build-all() {
  rm -v -f _bin/* _gen/*
  for name in "${EXAMPLES[@]}"; do
    if should-skip $name; then
      continue
    fi

    translate-example $name
    compile-example $name
  done
}

test-all() {
  mkdir -p _tmp

  time for name in "${EXAMPLES[@]}"; do
    if should-skip $name; then
      echo "  (skipping $name)"
      continue
    fi

    echo -n $name

    examples/${name}.py > _tmp/$name.python.txt 2>&1
    _bin/$name > _tmp/$name.cpp.txt 2>&1
    diff -u _tmp/$name.{python,cpp}.txt

    echo $'\t\t\tOK'
  done
}

benchmark-all() {
  # TODO: change this to iterations
  # BENCHMARK_ITERATIONS=1

  export BENCHMARK=1

  local out=_tmp/mycpp-examples.tsv

  # Create a new TSV file every time, and then append rows to it.

  # TODO:
  # - time.py should have a --header flag to make this more readable?
  # - More columns: -O1 -O2 -O3, machine, iterations of benchmark.
  echo $'status\tseconds\texample_name\tlanguage' > $out

  for name in "${EXAMPLES[@]}"; do
    banner $name

    echo
    echo $'\t[ C++ ]'
    time-tsv -o $out --field $name --field 'C++' -- _bin/$name

    echo
    echo $'\t[ Python ]'
    time-tsv -o $out --field $name --field 'Python' -- examples/${name}.py
  done

  cat $out
}

report() {
  R_LIBS_USER=$R_PATH ./examples.R report _tmp "$@"
}


#
# Utilities
#

grepall() {
  mypyc-files | xargs -- grep "$@"
}

count() {
  wc -l {mycpp,debug,cppgen,fib}.py
  echo
  wc -l *.cc *.h
}

cpp-compile-run() {
  local name=$1
  shift

  mkdir -p _bin
  cc -o _bin/$name $CPPFLAGS -I . $name.cc "$@" -lstdc++
  _bin/$name
}

target-lang() {
  cpp-compile-run target_lang
}

heap() {
  cpp-compile-run heap
}

runtime-test() {
  cpp-compile-run runtime_test runtime.cc
}

gen-ctags() {
  ctags -R $MYPY_REPO
}

"$@"
