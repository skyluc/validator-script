#!/bin/bash

####################################################################
# Build the whole chain from Scala (presumably downloaded from     #
# artifactory) to Scala-IDE, assuming checkouts of the appropriate #
# elements of said chain are organized in the $BASEDIR.            #
####################################################################

# This is for forcibly stopping the job from a subshell (see test
# below).
trap "exit 1" TERM
export TOP_PID=$$
set -e

# Known problems : does not fare well with interrupted, partial
# compilations. We should perhaps have a multi-dependency version
# of do_i_have below

RETRY=""
BUILDIT=""

ORIGPWD=`pwd`
BASEDIR="$HOME/Scala"
SCALADIR="$BASEDIR/scala/"
SBTDIR="$BASEDIR/sbt/"
SBINARYDIR="$BASEDIR/sbinary/"
REFACDIR="$BASEDIR/scala-refactoring/"
IDEDIR="$BASEDIR/scala-ide/"
if [ -z $SBT_HOME ]; then
    SBT_HOME=$HOME/.sbt/
fi

LOCAL_M2_REPO="$HOME/.m2/repository"
LOGGINGDIR="$HOME"

# :docstring usage:
# Usage: usage
# Prints a succint option help message.
# :end docstring:

function usage() {
    echo "Usage : $0 [-b] [-d] "
    echo "    -b : build Scala if it can't be downloaded"
    echo "    -d : retry downloading Scala rather than failing"
}


# :docstring with_backoff:
# Usage: with_backoff <argument ...>
# Executes <argument ...> with exponential backoff in case of
# failure.
# :end docstring:

function with_backoff(){
  local max_time=360
  local timeout=5
  local elapsed=0
  local exitCode=1

  while [[ $elapsed -lt $max_time ]]
  do
    set +e
    "$@"
    exitCode=$?
    set -e

    if [[ $exitCode == 0 ]]
    then
      break
    fi

    echo "### Failure! Retrying in $timeout ..." 1>&2
    sleep $timeout
    elapsed=$(( elasped + timeout ))
    timeout=$(( timeout * 2 ))
  done

  if [[ $exitCode != 0 ]]
  then
    echo "### Giving up! ($@)" 1>&2
  fi

  return $exitCode
}

# :docstring set_versions:
# Usage: set_versions
# Computes the hashes governing the version mangling of Scala/sbt/sbinary
# :end docstring:

function set_versions(){
    pushd $SCALADIR
    SCALAHASH=$(git rev-parse HEAD | cut -c 1-7)
    popd
    # despite the name, this has nothing to do with Scala, it's a
    # vanilla timestamp
    SCALADATE=`date +%Y-%m-%d-%H%M%S`

    SCALAMAJOR=$(sed -n 's/version.major=\([0-9]\)/\1/p' $SCALADIR/build.number)
    SCALAMINOR=$(sed -n 's/version.minor=\([0-9]\)/\1/p' $SCALADIR/build.number)
    SCALAPATCH=$(sed -n 's/version.patch=\([0-9]\)/\1/p' $SCALADIR/build.number)
    SCALAVERSION="$SCALAMAJOR.$SCALAMINOR.$SCALAPATCH"
    SCALASHORT="$SCALAMAJOR.$SCALAMINOR"

    if [[ -z $SCALAHASH || -z $SCALADATE || -z $SCALAVERSION ]]; then
        exit 125
    fi

    echo "### SCALA version detected : $SCALAVERSION-$SCALAHASH"| tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log

    SBINARYVERSION=$(sed -rn 's/[^t]*<sbinary\.version>([0-9]+\.[0-9]+\.[0-9]+(-pretending)?(-SNAPSHOT)?)<\/sbinary\.version>.*/\1/p' $IDEDIR/pom.xml|head -n 1)
    if [ -z $SBINARYVERSION ]; then exit 125; fi
    echo "### SBINARY version detected: \"$SBINARYVERSION\"" | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log

    # TODO : much better version detection: this is sensitive to
    # the order in which the profiles are declared for sbt !
    # <--- this is super sensitive stuff ---->
    if [[ $SCALAMINOR -gt 10 ]]; then
        SBTVERSION=$(sed -rn 's/[^t]*<sbt\.version>([0-9]+\.[0-9]+\.[0-9]+(-[M-R][0-9]+)?(-SNAPSHOT)?)<\/sbt\.version>.*/\1/p' $IDEDIR/pom.xml|tail -n 1)
    else
        SBTVERSION=$(sed -rn 's/[^t]*<sbt\.version>([0-9]+\.[0-9]+\.[0-9]+(-[M-R][0-9]+)?(-SNAPSHOT)?)<\/sbt\.version>.*/\1/p' $IDEDIR/pom.xml|head -n 1)
    fi
    # <--- this is super sensitive stuff ---->
    if [ -z $SBTVERSION ]; then exit 125; fi
    echo "### SBT version detected: \"$SBTVERSION\""| tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
}

# This is here because it requires set_versions
GENMVNOPTS="-e -X -Dmaven.repo.local=${LOCAL_M2_REPO}"
#REFACTOPS="-Dmaven.test.skip=true"
 REFACOPTS=""
# IDEOPTS="-Drepo.typesafe=http://repo.typesafe.com/typesafe/ide-$SCALASHORT"
IDEOPTS=""

# :docstring get_full_scala:
# Usage: get_full_scala
# This attempts to download Scala from Artifactory's
# typesafe/scala-pr-validation-snapshot, and copies it to the
# local maven repo
# :end docstring:

function get_full_scala(){
    mvn $GENMVNOPTS org.apache.maven.plugins:maven-dependency-plugin:2.1:get \
    -DrepoUrl=http://typesafe.artifactoryonline.com/typesafe/scala-pr-validation-snapshots/ \
    -Dartifact=org.scala-lang:scala-compiler:$SCALAVERSION-$SCALAHASH-SNAPSHOT \
    && mvn $GENMVNOPTS org.apache.maven.plugins:maven-dependency-plugin:2.1:get \
    -DrepoUrl=http://typesafe.artifactoryonline.com/typesafe/scala-pr-validation-snapshots/ \
    -Dartifact=org.scala-lang:scala-library:$SCALAVERSION-$SCALAHASH-SNAPSHOT
    if [[ ${PIPESTATUS[0]} -eq 0 && ${PIPESTATUS[1]} -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# :docstring ant-full-scala:
# Usage: ant-full-scala
# This builds Scala from source and publishes the resulting fact
# in the local maven repo. It does not run the test suite.
# :end docstring:

function ant-full-scala(){
    ant distpack -Dmaven.version.suffix="-`git rev-parse HEAD|cut -c 1-7`-SNAPSHOT"
    if [ $? -ne 0 ]; then
        echo "### SCALA FAILED"
        kill -s TERM $TOP_PID
    else
        cd dists/maven/latest
        ant deploy.snapshot.local
        cd -
        echo "### SCALA SUCCESS !"
    fi
}

# :docstring ant-clean:
# Usage: ant-clean
# This cleans a build repo in $SCALADIR, ignoring the mandatory
# dependency cache update check.
# :end docstring:

function ant-clean(){
    ant -Divy.cache.ttl.default=eternal all.clean
}

# :docstring do_i_have:
# Usage: do_i_have <groupId> <artifactId> <version>
# Tests if <groupId>:<artifactId>:jar:<version> is in the local maven repo.
# :end docstring:

function do_i_have(){
    say "### local repo test: trying to find $1:$2:jar:$3"
    CALLBACK=$(pwd)
    MVN_TEST_DIR=$(mktemp -d -t $1XXX)
    cd $MVN_TEST_DIR
    cat > pom.xml <<EOF
 <project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/maven-v4_0_0.xsd">
   <modelVersion>4.0.0</modelVersion>
   <groupId>com.typesafe</groupId>
   <artifactId>typesafeDummy</artifactId>
   <packaging>war</packaging>
   <version>1.0-SNAPSHOT</version>
   <name>Dummy</name>
   <url>http://127.0.0.1</url>
   <dependencies>
      <dependency>
         <groupId>$1</groupId>
         <artifactId>$2</artifactId>
         <version>$3</version>
         <scope>test</scope>
      </dependency>
   </dependencies>
</project>
EOF
    (mvn $GENMVNOPTS test)
    detmvn=${PIPESTATUS[0]}
    cd $CALLBACK
    rm -rf $MVN_TEST_DIR
    if [[ $detmvn -eq 0 ]]; then
        say "### $1:$2:jar:$3 found !"
    else
        say "### $1:$2:jar:$3 not in repo !"
    fi
    return $detmvn
}

# :docstring test:
# Usage: test <argument ..>
# Executes <argument ..>, logging the launch of the command to the
# main log file, and kills global script execution with the TERM
# signal if the commands ends up failing.
# :end docstring:

function test() {
    echo "### $@"
    "$@"
    status=$?
    if [ $status -ne 0 ]; then
        say "### ERROR with $1"
        cd $ORIGPWD
        kill -s TERM $TOP_PID
    fi
}

# :docstring say:
# Usage: say <argument ..>
# Prints <argument ..> to both console and the main log file.
# :end docstring:

function say(){
    (echo "$@") | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
}

# :docstring preparesbt:
# Usage: preparesbt
# This lets sbt know to look for the local maven repository.
# :end docstring:

function preparesbt(){
    if [ -f $SBT_HOME/repositories ]; then
        OLD_SBT_REPO_FILE=$(mktemp -t sbtreposXXX)
        cat $SBT_HOME/repositories > $OLD_SBT_REPO_FILE
    fi
    cat > $SBT_HOME/repositories <<EOF
[repositories]
  local
  maven-central
  typesafe-ivy-releases: http://repo.typesafe.com/typesafe/ivy-releases/, [organization]/[module]/[revision]/[type]s/[artifact](-[classifier]).[ext]
  mavenLocal: file:///$LOCAL_M2_REPO
EOF
}

# :docstring cleanupsbt:
# Usage: cleanupsbt
# This reestablishes the previous .sbt/repositories.
# :end docstring:

function cleanupsbt(){
    if [[ ! -z $OLD_SBT_REPO_FILE ]]; then
        mv $OLD_SBT_REPO_FILE $SBT_HOME/repositories
    else
        rm $SBT_HOME/repositories
    fi
}

# :docstring sbtbuild:
# Usage: sbtbuild
#
# To be launched from $SBTDIR. It needs .sbt/repositories to
# understand where to fetch Scala. Builds sbt and publishes
# it to the local maven repo. This depends on a '-pretending'-ised
# version of whatever sbinary version is in sbt's default
# config. If this '-pretending' is ever removed from Scala-IDE's main
# pom, it will need to be removed down here as well.
# :end docstring:

function sbtbuild(){
sbt -verbose "reboot full" clean "show scala-instance" "set every crossScalaVersions := Seq(\"$SCALAVERSION-$SCALAHASH-SNAPSHOT\")"\
     "set every version := \"$SBTVERSION\""\
     "set every scalaVersion := \"$SCALAVERSION-$SCALAHASH-SNAPSHOT\""\
     'set every Util.includeTestDependencies := false' \
     'set every scalaBinaryVersion <<= scalaVersion.identity' \
     'set (libraryDependencies in compilePersistSub) ~= { ld => ld map { case dep if (dep.organization == "org.scala-tools.sbinary") && (dep.name == "sbinary") => dep.copy(revision = (dep.revision + "-pretending-SNAPSHOT")) ; case dep => dep } }' \
     'set every publishMavenStyle := true' \
      "set every resolvers := Seq(\"Sonatype OSS Snapshots\" at \"https://oss.sonatype.org/content/repositories/snapshots\", \"Typesafe IDE\" at \"https://typesafe.artifactoryonline.com/typesafe/ide-$SCALASHORT\", \"Local maven\" at \"file://$LOCAL_M2_REPO\")" \
     'set artifact in (compileInterfaceSub, packageBin) := Artifact("compiler-interface")' \
     'set publishArtifact in (compileInterfaceSub, packageSrc) := false' \
     'set every credentials := Seq(Credentials(Path.userHome / ".credentials"))' \
     "set every publishTo := Some(Resolver.file(\"file\",  new File(\"$LOCAL_M2_REPO\")))" \
     'set every crossPaths := true' \
   +classpath/publish +logging/publish +io/publish +control/publish +classfile/publish +process/publish +relation/publish +interface/publish +persist/publish +api/publish +compiler-integration/publish +incremental-compiler/publish +compile/publish +compiler-interface/publish
}

# :docstring sbinarybuild:
# Usage: sbinarybuild
#
# To be launched from $SBINARYDIR. It needs .sbt/repositories to
# understand where to fetch Scala. Builds sbinary and publishes
# it to the local maven repo. This creates a '-pretending'-ised
# version of whatever sbinary version is in the repo's default
# config. If this '-pretending' is ever removed from Scala-IDE's main
# pom, it will need to be removed down here as well.
# :end docstring:

function sbinarybuild(){
  sbt "reboot full" clean "show scala-instance" \
  "set every scalaVersion := \"$SCALAVERSION-$SCALAHASH-SNAPSHOT\""\
  'set (version in core) ~= { v => v + "-pretending-SNAPSHOT" }' \
  "set every crossScalaVersions := Seq(\"$SCALAVERSION-$SCALAHASH-SNAPSHOT\")"\
  'set every scalaBinaryVersion <<= scalaVersion.identity' \
  'set (libraryDependencies in core) ~= { ld => ld flatMap { case dep if (dep.configurations.map(_ contains "test") getOrElse false)  => None; case dep => Some(dep) } }' \
  'set every publishMavenStyle := true' \
  "set every resolvers := Seq(\"Sonatype OSS Snapshots\" at \"https://oss.sonatype.org/content/repositories/snapshots\", \"Typesafe IDE\" at \"https://typesafe.artifactoryonline.com/typesafe/ide-$SCALASHORT\", \"Local maven\" at \"file://$LOCAL_M2_REPO\")" \
  'set every credentials := Seq(Credentials(Path.userHome / ".credentials"))' \
  "set every publishTo := Some(Resolver.file(\"file\",  new File(\"$LOCAL_M2_REPO\")))" \
  'set every crossPaths := true' \
  +core/publish +core/publish-local
}

# :docstring maven_fail_detect:
# Usage : maven_fail_detect [<myString>]
# This tests if a maven failure ("BUILD FAILURE") was encountered
# in the main log file. If so, it exit with error code 1. If not,
# it exits with 0 or continues, depending if (resp.) <myString> is
# empty or not.
# This is mostly used as a stateful sanity-check for failure.
# :end docstring:

function maven_fail_detect() {
    # failure detection
    grep -qe "BUILD\ FAILURE" $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
    if [ $? -ne 0 ]; then
        if [ -z $1 ]; then
            say "### No failure detected in log, exiting with 0"
            echo "log in $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log"
            exit 0
        else
            say "### No failure detected in log, continuing"
            return 0
        fi
    else
        say "### Failure  detected in log, exiting with 1"
        echo "log in $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log"
        exit 1
    fi
}

#####################
# BEGIN MAIN SCRIPT #
#####################

# look for the command line options
# again, single-letter options only because OSX's getopt is limited
set -- $(getopt db $*)
while [ $# -gt 0 ]
do
    case "$1" in
    (-d) RETRY=yes;;
    (-b) BUILDIT=yes;;
    (--) shift; break;;
    (-*) echo "$0: error - unrecognized option $1" 1>&2; usage; exit 1;;
    esac
    shift
done

set_versions
say "### logfile $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log"
# version logging
(test mvn -version) | tee $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log || exit 125

######################################################
# Building Scala, and publishing to local maven repo #
######################################################
# Try artifactory
set +e
if [ -z $RETRY ]; then
    get_full_scala
    getRetCode=$?
else
    with_backoff get_full_scala
    getRetCode=$?
fi
set -e
if [ $getRetCode -ne 0 ]; then
    say "### Fetching Scala $SCALAVERSION-$SCALAHASH-SNAPSHOT from artifactory failed ! (code $getRetCode)"
fi

# Check if the compiler isnt' already in the local maven
# Note : this assumes if scala-compiler is there, so is scala-library
set +e
do_i_have "org.scala-lang" "scala-compiler" "$SCALAVERSION-$SCALAHASH-SNAPSHOT"
already_built=$?
set -e
if [ $already_built -ne 0 ]; then
    if [ -z $BUILDIT ]; then
        say "### the Scala compiler was not found in local maven,"
        say "### and this script is not allowed to build it, exiting"
        exit 1
    else
        say "### the Scala compiler was not in local maven, building"
        cd $SCALADIR
        (test ant-clean) || exit 125
        (test git clean -fxd) || exit 125
        (test ant-full-scala) | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
    fi
else
    say "### the Scala compiler was found in local maven for $SCALAHASH"
fi

# Prepare .sbt/repositories resolution
# To do the minimal amount of change, this should properly be
# executed if (! do_i_have [sbinary_args] || ! do_i_have
# [sbt_args]) but it's too little gain to test for
(test preparesbt) || exit 125

#####################################################
# Building Sbinary to a local maven repo, if needed #
#####################################################

set +e
do_i_have "org.scala-tools.sbinary" "sbinary_$SCALAVERSION-$SCALAHASH-SNAPSHOT" "$SBINARYVERSION"
sbinaryres=$?
set -e
if [ $sbinaryres -ne 0 ]; then
    say "### SBinary result $sbinaryres"
    cd $SBINARYDIR
    (test git clean -fxd) || exit 125
    (test sbinarybuild) | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
    sbinary_return=${PIPESTATUS[0]}
    if [ $sbinary_return -ne 0 ]; then
        cd $ORIGPWD
        say "### SCALA-SBINARY FAILED !"
        exit 1
    else
        say "### SCALA-SBINARY SUCCESS !"
    fi
fi

#################################################
# Building SBT to a local maven repo, if needed #
#################################################

# TODO : This assumes if we have one of the projects in
# sbtbuild() above, we have them all. This is brittle if the sbt
# subproject dependency we test for (here, classpath) changes.

set +e
do_i_have "org.scala-sbt" "classpath_$SCALAVERSION-$SCALAHASH-SNAPSHOT" "$SBTVERSION"
sbtres=$?
set -e
if [ $sbtres -ne 0 ]; then
    cd $SBTDIR
    (test git clean -fxd) || exit 125
    (test sbtbuild) | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
    sbt_return=${PIPESTATUS[0]}
    if [ $sbt_return -ne 0 ]; then
        cd $ORIGPWD
        say "### SCALA-SBT FAILED !"
        exit 1
    else
        say "### SCALA-SBT SUCCESS !"
    fi
fi

# Remove .sbt/repositories scaffolding
(test cleanupsbt) || exit 125

################################
# Building scala-refactoring #
################################
# Note : because scala-refactoring is a dependency that is linked
# to completely dynamically (read : without version requirements)
# from custom update sites, looking for a maven artifact in a
# local package is fragile to the point of uselessness. Hence we
# have to rebuild it every time.
cd $REFACDIR
(test git clean -fxd) || exit 125
(test mvn $GENMVNOPTS -Dscala.version=$SCALAVERSION-$SCALAHASH-SNAPSHOT -Pscala-$SCALASHORT.x $REFACTOPS -Dgpg.skip=true clean install) | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
refac_return=${PIPESTATUS[0]}
if [ $refac_return -ne 0 ]; then
    cd $ORIGPWD
    say "### SCALA-REFACTORING FAILED !"
    exit 1
else
    say "### SCALA-REFACTORING SUCCESS !"
fi

# Tricky : this turns off fail on error, but test() lifts the
# restriction by killing the overall script in case of failure detection.
set +e
test maven_fail_detect "DontStopOnSuccess"
set -e

######################
# Building scala-ide #
######################
cd $IDEDIR
(test git clean -fxd) || exit 125
(test ./build-all.sh $GENMVNOPTS -Dscala.version=$SCALAVERSION-$SCALAHASH-SNAPSHOT $IDEOPTS -Pscala-$SCALASHORT.x clean install) | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
# (test ./build-all.sh $GENMVNOPTS -Dscala.version=$SCALAVERSION-$SCALAHASH-SNAPSHOT -Dsbt.compiled.version=$SCALAVERSION-SNAPSHOT $IDEOPTS -Pscala-$SCALASHORT.x clean install) | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
ide_return=${PIPESTATUS[0]}
if [ $ide_return -ne 0 ]; then
    cd $ORIGPWD
    say "### SCALA-IDE FAILED !"
else
    say "### SCALA-IDE SUCCESS !"
fi
maven_fail_detect
cd $ORIGPWD

###################
# END MAIN SCRIPT #
###################
