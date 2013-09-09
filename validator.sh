#!/bin/bash -ex

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
BASEDIR="$ORIGPWD"

# Make sure this is an absolute path with preceding '/'
LOGGINGDIR="$HOME"

# :docstring usage:
# Usage: usage
# Prints a succint option help message.
# :end docstring:

function usage() {
    echo "Usage : $0 [-b <basedir>] [-d] [-h <scalahash>] [-s]"
    echo "    -b : basedir where to find checkouts"
    echo "    -s : build Scala if it can't be downloaded"
    echo "    -j : override the check on Java version"
    echo "    -h : the 7-letter abbrev of the hash to build/retrieve"
    echo "    -l : the local maven repo to use (default BASEDIR/m2repo) "
    echo "Note : either -s or -h <scalahash> must be used"
}

# :docstring set_versions:
# Usage: set_versions
# Computes the hashes governing the version mangling of Scala/sbt/sbinary
# :end docstring:

function set_versions(){
    if [[ -z $SCALAHASH ]] || [[ ! -z $BUILDIT ]]; then
        pushd $SCALADIR
        SCALAHASH=$(git rev-parse HEAD | cut -c 1-7)
        popd
    fi
    if [ ${#SCALAHASH} -gt 7 ]; then
        SCALAHASH=`echo $SCALAHASH|cut -c 1-7`
    fi
    # despite the name, this has nothing to do with Scala, it's a
    # vanilla timestamp
    SCALADATE=`date +%Y-%m-%d-%H%M%S`

    # This is dirty!
    if [ ! -f $SCALADIR/build.number ]; then
        # <--- this is super sensitive stuff ---->
        SCALAMAJOR="2"
        SCALAMINOR="11"
        SCALAPATCH="0"
        # <--- this is super sensitive stuff ---->
    else
        SCALAMAJOR=$(sed -rn 's/version.major=([0-9])/\1/p' $SCALADIR/build.number)
        SCALAMINOR=$(sed -rn 's/version.minor=([0-9])/\1/p' $SCALADIR/build.number)
        SCALAPATCH=$(sed -rn 's/version.patch=([0-9])/\1/p' $SCALADIR/build.number)
    fi

    SCALAVERSION="$SCALAMAJOR.$SCALAMINOR.$SCALAPATCH"
    SCALASHORT="$SCALAMAJOR.$SCALAMINOR"
    REPO_SUFFIX=$(echo $SCALASHORT|tr -d '.')x

    if [[ -z $SCALAHASH ]] || [[ -z $SCALADATE ]] || [[ -z $SCALAVERSION ]]; then
        exit 125
    fi

    echo "### SCALA version detected : $SCALAVERSION-$SCALAHASH"| tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log

    SBINARYVERSION=$(sed -rn 's/[^t]*<sbinary\.version>([0-9]+\.[0-9]+\.[0-9]+(-pretending)?(-SNAPSHOT)?)<\/sbinary\.version>.*/\1/p' $IDEDIR/pom.xml|head -n 1)
    if [ -z $SBINARYVERSION ]; then exit 125; fi
    echo "### SBINARY version detected: \"$SBINARYVERSION\"" | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log

    # TODO : much better version detection: this is sensitive to
    # the order in which the profiles are declared for sbt !
    # WARNING : IDE has crazy dependencies on fictive SBT
    # versions ! (it mints custom versions every time it has an
    # incompatibility to fix)
    # <--- this is super sensitive stuff ---->
    if [[ $SCALAMINOR -gt 10 ]]; then
        SBTVERSION=$(sed -rn 's/[^t]*<sbt\.version>([0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z]+[0-9]+)?(-SNAPSHOT)?)<\/sbt\.version>.*/\1/p' $IDEDIR/pom.xml|tail -n 1)
    else
        SBTVERSION=$(sed -rn 's/[^t]*<sbt\.version>([0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z]+[0-9]+)?(-SNAPSHOT)?)<\/sbt\.version>.*/\1/p' $IDEDIR/pom.xml|tail -n 2|head -n 1)
    fi
    # <--- this is super sensitive stuff ---->
    if [ -z $SBTVERSION ]; then exit 125; fi
    echo "### SBT version detected: \"$SBTVERSION\""| tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log

    SBT_BOOTSTRAP_VERSION=$(sed -rn 's/sbt.version=([0-9]+\.[0-9]+\.[0-9]+)/\1/p' $SBTDIR/project/build.properties)
    echo "### SBT bootstraping version detected: \"$SBT_BOOTSTRAP_VERSION\""| tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
}

# :docstring scalariformbuild:
# Usage: scalariformbuild
# Builds scalariform and makes it available in maven.
# :end docstring:

function scalariformbuild()
{
    GIT_HASH=$(git rev-parse HEAD)

    # build scalariform
    say "### Building Scalariform"
    cd ${SCALARIFORMDIR}

    GIT_HASH=$(git rev-parse HEAD)

    mvn $GENMVNOPTS -Pscala-$SCALASHORT.x -Dscala.version=$SCALAVERSION-$SCALAHASH-SNAPSHOT -Dmaven.repo.local=$LOCAL_M2_REPO clean install

}


# :docstring ant-full-scala:
# Usage: ant-full-scala
# This builds Scala from source and publishes the resulting fact
# in the local maven repo. It does not run the test suite.
# :end docstring:

function ant-full-scala(){
    ant distpack-maven-opt -Darchives.skipxz=true -Dlocal.snapshot.repository="$LOCAL_M2_REPO" -Dversion.suffix="-$SCALAHASH-SNAPSHOT"
    if [ $? -ne 0 ]; then
        echo "### SCALA FAILED"
        kill -s TERM $TOP_PID
    else
        cd dists/maven/latest
        (test ant -Dlocal.snapshot.repository="$LOCAL_M2_REPO" -Dmaven.version.suffix="-$SCALAHASH-SNAPSHOT" deploy.local) | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
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
    if [ -f $DEST_REPO_FILE ]; then
        OLD_SBT_REPO_FILE=$(mktemp -t sbtreposXXX)
        cat $DEST_REPO_FILE > $OLD_SBT_REPO_FILE
    fi
    cat > $DEST_REPO_FILE <<EOF
[repositories]
  maven-central
  local
  typesafe-ivy-releases: http://repo.typesafe.com/typesafe/ivy-releases/, [organization]/[module]/[revision]/[type]s/[artifact](-[classifier]).[ext]
  sonatype-snapshots: https://oss.sonatype.org/content/repositories/snapshots
  sonatype-releases: https://oss.sonatype.org/content/repositories/releases
  mavenLocal: file://$LOCAL_M2_REPO
EOF
}

# :docstring cleanupsbt:
# Usage: cleanupsbt
# This reestablishes the previous .sbt/repositories.
# :end docstring:

function cleanupsbt(){
    say "### cleaning up $DEST_REPO_FILE"
    if [[ ! -z $OLD_SBT_REPO_FILE ]]; then
        mv $OLD_SBT_REPO_FILE $DEST_REPO_FILE
    else
        rm $DEST_REPO_FILE
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
    if [ -f project/build.properties ]; then
        OLD_BUILDPROPERTIES_FILE=$(mktemp -t buildpropsXXX)
        cat project/build.properties > $OLD_BUILDPROPERTIES_FILE
        sed -ir "s/sbt\.version=.*/sbt.version=$SBT_BOOTSTRAP_VERSION/" project/build.properties
    else
        echo "sbt.version=$SBT_BOOTSTRAP_VERSION" > project/build.properties
    fi
    echo "sbt.repository.config=$DEST_REPO_FILE" >> project/build.properties
    echo "sbt.override.build.repos=true" >> project/build.properties
    echo "### forcing sbt to look at sbt-dir $EXTRASBTDIR"

    set +e
    sbt $EXTRASBTDIR -verbose -debug  -Dsbt.ivy.home=$IVY_CACHE/.cache/.ivy2/ "reboot full" clean "show scala-instance" "set every crossScalaVersions := Seq(\"$SCALAVERSION-$SCALAHASH-SNAPSHOT\")"\
     "set every version := \"$SBTVERSION\""\
     "set every scalaVersion := \"$SCALAVERSION-$SCALAHASH-SNAPSHOT\""\
     'set every Util.includeTestDependencies := false' \
        'set every scalaBinaryVersion <<= scalaVersion.identity' \
        'set (libraryDependencies in compilePersistSub) ~= { ld => ld map { case dep if (dep.organization == "org.scala-tools.sbinary") && (dep.name == "sbinary") => dep.copy(revision = (dep.revision + "-SNAPSHOT")) ; case dep => dep } }' \
        'set every publishMavenStyle := true' \
        "set every resolvers := Seq(\"Sonatype OSS Snapshots\" at \"https://oss.sonatype.org/content/repositories/snapshots\", \"Typesafe IDE\" at \"https://private-repo.typesafe.com/typesafe/ide-$SCALASHORT\", \"Local maven\" at \"file://$LOCAL_M2_REPO\")" \
        'set artifact in (compileInterfaceSub, packageBin) := Artifact("compiler-interface")' \
        'set publishArtifact in (compileInterfaceSub, packageSrc) := false' \
        'set every credentials := Seq(Credentials(Path.userHome / ".credentials"))' \
        "set every publishTo := Some(Resolver.file(\"file\",  new File(\"$LOCAL_M2_REPO\")))" \
        'set every crossPaths := true' \
        +classpath/publish +logging/publish +io/publish +control/publish +classfile/publish +process/publish +relation/publish +interface/publish +persist/publish +api/publish +compiler-integration/publish +incremental-compiler/publish +compile/publish +compiler-interface/publish
    sbt_return=$?
    set -e

    if [[ ! -z $OLD_BUILDPROPERTIES_FILE ]]; then
        mv $OLD_BUILDPROPERTIES_FILE project/build.properties
    else
        rm project/build.properties
    fi
    return $sbt_return
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
    if [ -f project/build.properties ]; then
        OLD_BUILDPROPERTIES_FILE=$(mktemp -t buildpropsXXX)
        cat project/build.properties > $OLD_BUILDPROPERTIES_FILE
        sed -ir "s/sbt\.version=.*/sbt.version=$SBT_BOOTSTRAP_VERSION/" project/build.properties
    else
        echo "sbt.version=$SBT_BOOTSTRAP_VERSION" > project/build.properties
    fi
    echo "sbt.repository.config=$DEST_REPO_FILE" >> project/build.properties
    echo "sbt.override.build.repos=true" >> project/build.properties
    echo "### forcing sbt to look at sbt-dir $EXTRASBTDIR"

    set +e
    sbt $EXTRASBTDIR -verbose -debug -Dsbt.ivy.home=$IVY_CACHE/.cache/.ivy2/ "reboot full" clean "show scala-instance" \
  "set every scalaVersion := \"$SCALAVERSION-$SCALAHASH-SNAPSHOT\""\
  "set (version in core) := \"$SBINARYVERSION\"" \
  "set every crossScalaVersions := Seq(\"$SCALAVERSION-$SCALAHASH-SNAPSHOT\")"\
  'set every scalaBinaryVersion <<= scalaVersion.identity' \
  'set (libraryDependencies in core) ~= { _ filterNot (_.configurations.map(_ contains "test").getOrElse(false)) }' \
  'set every publishMavenStyle := true' \
  "set every resolvers := Seq(\"Sonatype OSS Snapshots\" at \"https://oss.sonatype.org/content/repositories/snapshots\", \"Typesafe IDE\" at \"https://private-repo.typesafe.com/typesafe/ide-$SCALASHORT\", \"Local maven\" at \"file://$LOCAL_M2_REPO\")" \
  'set every credentials := Seq(Credentials(Path.userHome / ".credentials"))' \
  "set every publishTo := Some(Resolver.file(\"file\",  new File(\"$LOCAL_M2_REPO\")))" \
  'set every crossPaths := true' \
  +core/publish +core/publish-local
    sbinary_return=$?
    set -e

    if [[ ! -z $OLD_BUILDPROPERTIES_FILE ]]; then
        mv $OLD_BUILDPROPERTIES_FILE project/build.properties
    else
        rm project/build.properties
    fi
    return $sbinary_return
}

# :docstring maven_fail_detect:
# Usage : maven_fail_detect [<myString>]
# This tests if a maven failure ("BUILD FAILURE") was encountered
# in the main log file. If so, it exits with error code 1. If not,
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
set -- $(getopt sjb:h:l: $*)
while [ $# -gt 0 ]
do
    case "$1" in
    (-b) BASEDIR=$2; shift;;
    (-s) BUILDIT=yes;;
    (-h) SCALAHASH=$2;;
    (-j) JAVAOVERRIDE=yes;;
    (-l) LOCAL_M2_REPO=$2;;
    (--) shift; break;;
    (-*) echo "$0: error - unrecognized option $1" 1>&2; usage; exit 1;;
    esac
    shift
done

# prerequisites
# Java 1.6.x
if [ -z $JAVAOVERRIDE ]; then
    JAVA_VERSION=$(javaoo -version 2>&1 | grep 'java version' | awk -F '"' '{print $2;}')
    JAVA_SHORT_VERSION=${JAVA_VERSION:0:3}
    if [ "1.6" != "${SHORT_VERSION}" ]; then
        echo "Please run the validator with Java 1.6."
        exit 2
    fi
fi

if [[ -z "$LOCAL_M2_REPO" ]]; then
    LOCAL_M2_REPO="$BASEDIR/m2repo"
fi

echo "### M2 REPO set to : $LOCAL_M2_REPO"

SCALADIR="$BASEDIR/scala/"
if [[ -z $BUILDIT && -z $SCALAHASH && ! -d $SCALADIR ]]; then
    echo "-h must be used or a source repo provided when not building Scala from source"
    usage
    exit 1
fi

SBTDIR="$BASEDIR/sbt/"
SBINARYDIR="$BASEDIR/sbinary/"
REFACDIR="$BASEDIR/scala-refactoring/"
SCALARIFORMDIR="$BASEDIR/scalariform"
IDEDIR="$BASEDIR/scala-ide/"
if [ -z $SBT_HOME ]; then
    SBT_HOME="$HOME/.sbt"
fi

set_versions
say "### logfile $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log"
# This is here because it requires set_versions
GENMVNOPTS="-e -X -Dmaven.repo.local=${LOCAL_M2_REPO}"
#REFACTOPS="-Dmaven.test.skip=true"
 REFACOPTS=""
# IDEOPTS="-Drepo.typesafe=http://repo.typesafe.com/typesafe/ide-$SCALASHORT"
IDEOPTS=""
# version logging
(test mvn -version) | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log || exit 125

######################################################
# Building Scala, and publishing to local maven repo #
######################################################
# First, look at $SCALADIR to see if it contains to-be-deployed
# artifacts
if [ -d $SCALADIR/dists/maven/latest ]; then
    say "### found a $SCALADIR/dists/maven/latest, deploying it"
    # Let's deploy the found compiler
    cd $SCALADIR/dists/maven/latest
    # check hash corresponds to either the $SCALAHASH
    # from command line or the hash determined from source repo
    git_deployee=$(sed -rn 's/env.GIT_COMMIT=([0-9a-e]+)/\1/p' build.properties |cut -c 1-7)
    # If there is no readme, it's an artifical repo running for
    # validation, so the process of distributing whatever is in
    # dists/maven under the command-line hash is OK. If there is
    # one this is a scala checkout, and I need to be a bit more clever.
    if [[ ! -f $SCALADIR/Readme.rst ]] || [[ $git_deployee = $SCALAHASH ]]; then
        (test ant -Dmaven.version.number=$SCALAVERSION-$SCALAHASH-SNAPSHOT -Dlocal.snapshot.repository="$LOCAL_M2_REPO" -Dmaven.version.suffix="-$SCALAHASH-SNAPSHOT" deploy.local) | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
        cd -
    else
        say "### the $SCALADIR/dists/maven/latest distrib does not match the hash of $SCALAHASH I am supposed to build, aborting"
        exit 1
    fi
fi

# Check if the compiler isnt' already in the local maven
# Note : this assumes if scala-compiler is there, so is scala-library
set +e
do_i_have "org.scala-lang" "scala-compiler" "$SCALAVERSION-$SCALAHASH-SNAPSHOT"
already_built=$?
set -e
if [ $already_built -ne 0 ]; then
    if [ -z $BUILDIT ]; then
        say "### the Scala compiler was not found in local maven $LOCAL_M2_REPO,"
        say "### and this script is not allowed to build it, exiting"
        exit 1
    else
        say "### the Scala compiler was not in local maven $LOCAL_M2_REPO, building"
        cd $SCALADIR
        export ANT_OPTS="-Xms512M -Xmx2048M -Xss1M -XX:MaxPermSize=128M"
        full_hash=$(git rev-parse $SCALAHASH)
        set +e
        response=$(curl --write-out %{http_code} --silent --output /dev/null "http://scala-webapps.epfl.ch/artifacts/$full_hash")
        set -e
        # you get 000 if you are offline
        if [ $response -ne 404 ] && [ $response -ne 000 ]; then
            say "### the Scala compiler was found in scala-webapps! deploying this version"
            rm -f maven.tgz
            wget "http://scala-webapps.epfl.ch/artifacts/$full_hash/maven.tgz"
            mkdir -p dists/maven/
            pushd dists/maven/
            tar xzvf ../../maven.tgz
            cd latest
            (test ant -Dmaven.version.number=$SCALAVERSION-$SCALAHASH-SNAPSHOT -Dlocal.snapshot.repository="$LOCAL_M2_REPO" -Dmaven.version.suffix="-$SCALAHASH-SNAPSHOT" deploy.local) | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
            cd -
            popd
            rm maven.tgz
            do_i_have "org.scala-lang" "scala-compiler" "$SCALAVERSION-$SCALAHASH-SNAPSHOT"
            if [[ ! $? -eq 0 ]]; then
                say "### deployment failed ! aborting"
                echo  "### deployment failed ! aborting"
                exit 125
            fi
        else
            (test ant-clean) || exit 125
            (test git clean -fxd) || exit 125
            (test ant-full-scala) | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
        fi
    fi
else
    say "### the Scala compiler was found in local maven $LOCAL_M2_REPO for $SCALAHASH"
fi

# Prepare .sbt/repositories resolution
# Am I using sbt-extras ?
set +e
sbt --version 2>&1|head -n 1|grep -qe "Detected"
sbt_extraed=$?
set -e
if [ $sbt_extraed -eq 0 ]; then
    SBT_INSTALLED=$(sbt --version 2>&1 |head -n 1|sed -rn 's/.*?([0-9]+\.[0-9]+\.[0-9]+(-[A-Z 0-9]+)?)/\1/p')
    if [ -z $SBT_BOOTSTRAP_VERSION ]; then
        SBT_BOOTSTRAP_VERSION=$SBT_INSTALLED
    fi
    DEST_REPO_FILE=$SBT_HOME/$SBT_BOOTSTRAP_VERSION/repositories
    mkdir -p $SBT_HOME/$SBT_BOOTSTRAP_VERSION
    say "### sbt-extras detected, will write resolvers to $DEST_REPO_FILE"
    EXTRASBTDIR="-sbt-dir ${DEST_REPO_FILE%\/repositories}"
else
    DEST_REPO_FILE=$SBT_HOME/repositories
    say "### vanilla sbt detected, will write resolvers to $DEST_REPO_FILE"
fi
# To do the minimal amount of change, this should properly be
# executed if (! do_i_have [sbinary_args] || ! do_i_have
# [sbt_args]) but it's too little gain to test for
IVY_CACHE=$(mktemp -d -t ivycacheXXX)
(test preparesbt) || exit 125

#####################################################
# Building Sbinary to a local maven repo, if needed #
#####################################################

set +e
do_i_have oro oro "2.0.8"
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
    # TODO : make this much less brittle (see version detection above)
    # <--- this is super sensitive stuff ---->
    if $(git show-ref --tags|grep -qe "v${SBTVERSION%-SNAPSHOT}"); then
        set +e
        git checkout "v${SBTVERSION%-SNAPSHOT}"
        set -e
    fi
    # <--- this is super sensitive stuff ---->
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
(pushd $SBTDIR && git checkout project/build.properties && popd) || exit 125


########################
# Building scalarifom  #
########################
cd $SCALARIFORMDIR

(test scalariformbuild) | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
scalariform_return=${PIPESTATUS[0]}
if [ $scalariform_return -ne 0 ]; then
    cd $ORIGPWD
    say "### SCALARIFORM FAILED !"
    exit 1
else
    say "### SCALARIFORM SUCCESS !"
fi


################################
# Building scala-refactoring   #
################################
# Note : because scala-refactoring is a dependency that is linked
# to (from IDE) completely dynamically (read : w/o version requirements)
# from custom update sites, looking for a maven artifact in a
# local package is fragile to the point of uselessness. Hence we
# have to rebuild it every time.
cd $REFACDIR
(test git clean -fxd) || exit 125
(test mvn $GENMVNOPTS -DskipTests=false -Dscala.version=$SCALAVERSION-$SCALAHASH-SNAPSHOT -Pscala-$SCALASHORT.x $REFACTOPS -Dgpg.skip=true clean install) | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
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
# -Dtycho.disableP2Mirrors=true -- when mirrors are slow
(test ./build-all.sh $GENMVNOPTS -DskipTests=false -Dscala.version=$SCALAVERSION-$SCALAHASH-SNAPSHOT -Dsbt.version=$SBTVERSION -Dsbt.ide.version=$SBTVERSION $IDEOPTS -Pscala-$SCALASHORT.x -Peclipse-juno -Psbt-legacy clean install) | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
ide_return=${PIPESTATUS[0]}
if [ $ide_return -ne 0 ]; then
    cd $ORIGPWD
    say "### SCALA-IDE FAILED !"
else
    say "### SCALA-IDE SUCCESS !"
fi
set +e
test maven_fail_detect
set -e
cd $ORIGPWD
exit 0

###################
# END MAIN SCRIPT #
###################
