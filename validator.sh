#!/bin/bash
trap "exit 1" TERM
export TOP_PID=$$

ORIGPWD=`pwd`
BASEDIR="$HOME/Scala"
SCALADIR="$BASEDIR/scala/"
SBTDIR="$BASEDIR/sbt/"
SBINARYDIR="$BASEDIR/sbinary/"
REFACDIR="$BASEDIR/scala-refactoring/"
IDEDIR="$BASEDIR/scala-ide/"

LOCAL_M2_REPO="$HOME/.m2/repository"
LOGGINGDIR="$HOME"

# Set the hash
function set_versions(){
    pushd $SCALADIR
    SCALAHASH=$(git rev-parse HEAD | cut -c 1-7)
    popd
    SCALADATE=`date +%Y-%m-%d-%H%M%S`

    SCALAMAJOR=$(sed -n 's/version.major=\([0-9]\)/\1/p' $SCALADIR/build.number)
    SCALAMINOR=$(sed -n 's/version.minor=\([0-9]\)/\1/p' $SCALADIR/build.number)
    SCALAPATCH=$(sed -n 's/version.patch=\([0-9]\)/\1/p' $SCALADIR/build.number)
    SCALAVERSION="$SCALAMAJOR.$SCALAMINOR.$SCALAPATCH"
    SCALASHORT="$SCALAMAJOR.$SCALAMINOR"

    SBTVERSION=$(sed -rn 's/[
    ^t]*<sbt\.version>([0-9]+\.[0-9]+\.[0-9]+(-[M-R][0-9]+)?(-SNAPSHOT)?)<\/sbt\.version>.*/\1/p' $IDEDIR/pom.xml|head -n 1)
}

GENMVNOPTS="-e -X -Dmaven.repo.local=${LOCAL_M2_REPO}"
#REFACTOPS="-Dmaven.test.skip=true"
 REFACOPTS=""
# IDEOPTS="-Drepo.typesafe=http://repo.typesafe.com/typesafe/ide-$SCALASHORT"
IDEOPTS=""

function get_full_scala(){
    (mvn org.apache.maven.plugins:maven-dependency-plugin:2.1:get \
    -DrepoUrl=http://typesafe.artifactoryonline.com/typesafe/scala-pr-validation-snapshots/ \
    -Dartifact=org.scala-lang:scala-compiler:$SCALAVERSION-$SCALAHASH-SNAPSHOT \
    && mvn org.apache.maven.plugins:maven-dependency-plugin:2.1:get \
    -DrepoUrl=http://typesafe.artifactoryonline.com/typesafe/scala-pr-validation-snapshots/ \
    -Dartifact=org.scala-lang:scala-library:$SCALAVERSION-$SCALAHASH-SNAPSHOT) || return 1
}

function ant-full-scala(){
    ant distpack -Dmaven.version.suffix="-`git rev-parse HEAD|cut -c 1-7`-SNAPSHOT"
    ant_return=$?
    if [ $ant_return -ne 0 ]; then
        echo "### SCALA FAILED"
        kill -s TERM $TOP_PID
    else
        cd dists/maven/latest
        ant deploy.snapshot.local
        cd -
        echo "### SCALA SUCCESS !"
    fi
}

function ant-clean(){
    ant -Divy.cache.ttl.default=eternal all.clean
}

function test() {
    echo "### $@"
    "$@"
    status=$?
    if [ $status -ne 0 ]; then
        echo "### ERROR with $1"
        cd $ORIGPWD
        kill -s TERM $TOP_PID
    fi
}

function say(){
    echo "$@" | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
}

function preparesbt(){
    if [ -f $HOME/.sbt/repositories ]; then
        OLD_SBT_REPO_FILE=$(mktemp -t sbtreposXXX)
        cat $HOME/.sbt/repositories > $OLD_SBT_REPO_FILE
    fi
    echo '[repositories]' > $HOME/.sbt/repositories
    echo '  local' >> $HOME/.sbt/repositories
    echo '  maven-central' >> $HOME/.sbt/repositories
    echo '  typesafe-ivy-releases: http://repo.typesafe.com/typesafe/ivy-releases/, [organization]/[module]/[revision]/[type]s/[artifact](-[classifier]).[ext]' >> $HOME/.sbt/repositories
    echo "  mavenLocal: file://$LOCAL_M2_REPO" >> $HOME/.sbt/repositories
}

function cleanupsbt(){
    if [[ ! -z $OLD_SBT_REPO_FILE ]]; then
        mv $OLD_SBT_REPO_FILE $HOME/.sbt/repositories
    else
        rm $HOME/.sbt/repositories
    fi
}

function sbtbuild(){
sbt -verbose "reboot full" clean "show scala-instance" "set every crossScalaVersions := Seq(\"$SCALAVERSION-$SCALAHASH-SNAPSHOT\")"\
     "set every version := \"$SBTVERSION \""\
     "set every scalaVersion := \"$SCALAVERSION-$SCALAHASH-SNAPSHOT\""\
     'set every Util.includeTestDependencies := false' \
     'set every scalaBinaryVersion <<= scalaVersion.identity' \
     'set (libraryDependencies in compilePersistSub) ~= { ld => ld map { case dep if (dep.organization == "org.scala-tools.sbinary") && (dep.name == "sbinary") => dep.copy(revision = (dep.revision + "-pretending-SNAPSHOT")) ; case dep => dep } }' \
     'set every publishMavenStyle := true' \
      "set every resolvers := Seq(\"Sonatype OSS Snapshots\" at \"https://oss.sonatype.org/content/repositories/snapshots\", \"Typesafe IDE\" at \"https://typesafe.artifactoryonline.com/typesafe/ide-$SCALASHORT\", \"Local maven\" at \"file://$LOCAL_M2_REPO\")" \
     'set artifact in (compileInterfaceSub, packageBin) := Artifact("compiler-interface")' \
     'set publishArtifact in (compileInterfaceSub, packageSrc) := false' \
     'set every credentials := Seq(Credentials(Path.userHome / ".credentials"))' \
     'set every publishTo := Some(Resolver.file("file",  new File("$LOCAL_M2_REPO")))' \
     'set every crossPaths := true' \
   +classpath/publish +logging/publish +io/publish +control/publish +classfile/publish +process/publish +relation/publish +interface/publish +persist/publish +api/publish +compiler-integration/publish +incremental-compiler/publish +compile/publish +compiler-interface/publish
}

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
  'set every publishTo := Some(Resolver.file("file",  new File("$LOCAL_M2_REPO")))' \
  'set every crossPaths := true' \
  +core/publish +core/publish-local
}

function maven_fail_detect() {
    # failure detection
    grep -qe "BUILD\ FAILURE" $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
    if [ $? -ne 0 ]; then
        say "Failure not detected in log, exiting with 0"
        echo "log in $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log"
        exit 0
    else
        say "Failure  detected in log, exiting with 1"
        echo "log in $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log"
        exit 1
    fi
}

test set_versions || exit 125
echo "### $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log"
# version logging
(test mvn -version) | tee $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log || exit 125

# building Scala
cd $SCALADIR
(test ant-clean) || exit 125
(test git clean -fxd) || exit 125
# Try artifactory
(get_full_scala)
if [ $? -ne 0 ]; then
    say "### fetching Scala $SCALAVERSION-$SCALAHASH-SNAPSHOT from artifactory failed !"
fi
already_built=$(find $LOCAL_M2_REPO -type f -iname "scala-compiler-$SCALAVERSION-$SCALAHASH-SNAPSHOT.jar")
if [ -z $already_built ]; then
    say "### the Scala compiler was not in local maven, building"
    (test ant-full-scala) | tee -a $LOGGINGDIR/compilation-$SCALADATE-$SCALAHASH.log
else
    say "### the Scala compiler was found in local maven for $SCALAHASH"
fi

# prepare .sbt/repositories
(test preparesbt) || exit 125

# building Sbinary to a local maven repo
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


# #building SBT
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

# remove .sbt/repositories scaffolding
(test cleanupsbt) || exit 125

# building scala-refactoring
cd $REFACDIR
# (test mvn $GENMVNOPTS clean) || exit 125
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
maven_fail_detect

# building scala-ide
cd $IDEDIR
# (test mvn $GENMVNOPTS clean) || exit 125
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
