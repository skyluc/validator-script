#!/bin/bash
# Simple repo preparation script:
# We clone with the specified commit of Scala, and the latest
# versions of sbinary, sbt, scala-refactoring and scala-ide.

function usage() {
    echo "Usage : $0 [-s <scala-commit>] [-b <basedir>]"
}

CLONESCALA=""
set -- $(getopt s:b: $*)
while [ $# -gt 0 ]
do
    case "$1" in
    (-s)    CLONESCALA=yes;
            SCALACOMMIT=$2;
            echo "processing Scala with commit $SCALACOMMIT";
            shift;;
    (-b) BASEDIR=$2; shift;;
    (--) shift; break;;
    (-*) echo "$0: error - unrecognized option $1" 1>&2; usage; exit 1;;
    esac
    shift
done

if [ ! -n $BASEDIR ]; then
    BASEDIR=$(mktemp -dt scala-ide-validationXXX)
fi
echo "Will use $BASEDIR"

if [ -n $SCALACOMMIT ]; then SCALACOMMIT="master"; fi

ORIGPWD=`pwd`
SCALADIR="$BASEDIR/scala/"
SBTDIR="$BASEDIR/sbt/"
SBINARYDIR="$BASEDIR/sbinary/"
REFACDIR="$BASEDIR/scala-refactoring/"
IDEDIR="$BASEDIR/scala-ide/"

if [ ! -d $BASEDIR ]; then mkdir -p $BASEDIR; fi

cd $BASEDIR
if [ ! -z $CLONESCALA ]; then
    # on average, 1K commits betw 2 Scala milestones
    git clone --depth 2000 git://github.com/scala/scala.git
    pushd $SCALADIR
    git checkout $SCALACOMMIT
    popd
fi

# on average, < 10 commits betw sbinary chosen versions
git clone --depth 20 git://github.com/scala-ide/sbinary.git
# this depends on the fact that the default clone checkout is the
# dev branch (master or the local equivalent)

# on average, 80 commits betw 2 sbt milestones
git clone --depth 160 git://github.com/sbt/sbt.git
# this depends on the fact that the default clone checkout is the
# dev branch (master or the local equivalent)

# on average, 50 commits betw 2 refactoring releases
git clone --depth 100 git://github.com/scala-ide/scala-refactoring.git
# this depends on the fact that the default clone checkout is the
# dev branch (master or the local equivalent)

# on average, 350 commits betw 2 ide releases
git clone --depth 700 git://github.com/scala-ide/scala-ide.git
# this depends on the fact that the default clone checkout is the
# dev branch (master or the local equivalent)

cd $ORIGPWD
