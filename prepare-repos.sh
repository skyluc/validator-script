#!/bin/bash
# Simple repo preparation script:
# We clone with the specified commit of Scala, and the latest
# versions of sbinary, sbt, scala-refactoring and scala-ide.

SCALAURL="git://github.com/scala/scala.git"
SBINARYURL="git://github.com/scala-ide/sbinary.git"
SBTURL="git://github.com/sbt/sbt.git"
SCALARIFORMURL="git://github.com/mdr/scalariform.git"
REFACURL="git://github.com/scala-ide/scala-refactoring.git"
IDEURL="git://github.com/scala-ide/scala-ide.git"

function usage() {
    echo "Usage : $0 [-s <scala-commit>] [-b <basedir>]"
}


# :docstring getOrUpdate:
# Usage : getOrUpdate <directory> <url> <reference> <n>
#
# Updates or clones the checkout of <reference> taken from the
# git repo at <url> into the local directory
# <directory>. <reference> should not be older than the last <n>
# commits from the top of the repo. at creation of the checkout.
# All arguments are required.
#
# :end docstring:

function getOrUpdate(){
    local deepen=''
    if [ ! -d $1 ]; then
        git clone --depth 1 $2
        deepen='true'
    else
        pushd $1
        originUrl=$(git config --get remote.origin.url)
        if [ ! $originUrl = $2 ]; then
            echo "Can't understand repository structure in $1, aborting"
            exit 1
        fi
        git fetch origin
        popd
    fi
    pushd $1
    git checkout -q $3
    if [ $deepen ]; then
        echo "Deepening $1 by $4 commits"
        git fetch --depth $4
    fi
    popd
}

set -- $(getopt h:b: $*)
while [ $# -gt 0 ]
do
    case "$1" in
    (-h)    SCALACOMMIT=$2;
            echo "processing Scala with commit $SCALACOMMIT";
            shift;;
    (-b) BASEDIR=$2; shift;;
    (--) shift; break;;
    (-*) echo "$0: error - unrecognized option $1" 1>&2; usage; exit 1;;
    esac
    shift
done

ORIGPWD=`pwd`
if [ -z $BASEDIR ]; then
    BASEDIR=$ORIGPWD
fi
echo "Will use $BASEDIR"
SCALADIR="$BASEDIR/scala/"
SBTDIR="$BASEDIR/sbt/"
SBINARYDIR="$BASEDIR/sbinary/"
SCALARIFORMDIR="$BASEDIR/scalariform"
REFACDIR="$BASEDIR/scala-refactoring/"
IDEDIR="$BASEDIR/scala-ide/"

if [ ! -d $BASEDIR ]; then mkdir -p $BASEDIR; fi

cd $BASEDIR
# on average, 1K commits betw 2 Scala milestones
# on average, < 10 commits betw sbinary chosen versions
# on average, 80 commits betw 2 sbt milestones
# on average, < 10 commits betw scalariform chosen versions
# on average, 50 commits betw 2 refactoring releases
# on average, 350 commits betw 2 ide releases
if [ -z $SCALACOMMIT ]; then
    getOrUpdate $SCALADIR $SCALAURL $SCALACOMMIT 2000
fi
getOrUpdate $SBINARYDIR $SBINARYURL "origin/HEAD" 20
# TODO : fix up some symbolic-ref detection for sbt, this is
# gonna blow up in our face
getOrUpdate $SBTDIR $SBTURL "origin/HEAD" 160
getOrUpdate $SCALARIFORMDIR $SCALARIFORMURL "origin/HEAD" 20
getOrUpdate $REFACDIR $REFACURL "origin/HEAD" 100
getOrUpdate $IDEDIR $IDEURL "origin/HEAD" 700

# ths depends on the fact that the default clone checkout is the
# dev branch (master or the local equivalent)

cd $ORIGPWD
