#!/usr/bin/env perl
# TestEnvironment.pm: A class representing an Elixir test environment.
# See license information at end of file.
#
# For a cleaner view of the documentation, run
#   perldoc TestEnvironment.pm
# (on Ubuntu, you may need to install the perl-doc package first.)
#
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# This file uses only core Perl modules, and modules bundled with
# the Elixir distribution.

=head1 NAME

TestEnvironment - Class representing an Elixir test environment

=head1 SYNOPSIS

    use TestEnvironment;
    my $tenv = TestEnvironment->new;
    $tenv->build_repo($source_path);    # Make a git repo
    $tenv->build_db($db_path);          # Run update.py
    $tenv->export_env;                  # Set $LXR_* environment vars
    # Now run tests against the database in $db_path

=cut

package TestEnvironment;

use TestClass;  # Now we are a class
use autodie;    # note: still need to check system() calls manually

use Cwd qw(abs_path);
use File::Path qw(remove_tree);
use File::Spec;
use File::Temp 0.14 qw(tempdir);
use FindBin;
use IO::Select;
use IPC::Open3;
use Symbol;

use Test::More;

use TestHelpers;

=head1 ATTRIBUTES

=head2 lxr_data_dir

C<$lxr_data_dir> is the value to use in the C<LXR_DATA_DIR> environment
variable.

=head2 lxr_repo_dir

C<$lxr_repo_dir> is the value to use in the C<LXR_REPO_DIR> environment
variable.

=head2 script_sh

The path to C<script.sh>.  Assigned by default using
C<TestHelpers/find_program> if not specified.

=head2 query_py

As L</script_sh>, but for C<query.py>.

=head2 update_py

As L</script_sh>, but for C<update.py>.

=cut

has lxr_data_dir => ();
has lxr_repo_dir => ();
has script_sh => (
    default => sub { find_program('script.sh') }
);
has query_py => (
    default => sub { find_program('query.py') }
);
has update_py => (
    default => sub { find_program('update.py') }
);

# Internal attributes

# a variable representing the temporary repository directory.
# When this goes out of scope, the directory will be removed.
has _repo_dir_token => ();

# a variable representing the temporary DB directory, if any.
# When this goes out of scope, the directory will be removed.
has _data_dir_token => ();

=head1 MEMBER FUNCTIONS

=head2 build_repo

Create a Git repo and tag it.  Usage:

    $tenv->build_repo($source_tree_dir);

C<$source_tree_dir> is the directory holding the tree of source files
you want to index.

Dies on error.  On success, returns the instance, for chaining.

=cut

sub build_repo {
    my ($self, $tree_src_dir) = @_;
    die "Need a source dir" unless $tree_src_dir;

    my $tempdir = tempdir(CLEANUP => 1);
    my $tempdir_path = abs_path($tempdir);
    my @gitdir = ('-C', $tempdir_path);

    diag "Using temporary directory $tempdir_path";
    run_program('git', 'init', $tempdir_path) or die("git init failed");

    run_program('bash', '-c', "tar cf - -C \"$tree_src_dir\" . | tar xf - -C \"$tempdir_path\"")
        or die("Could not copy files into $tempdir_path");

    run_program('git', @gitdir, 'add', '.') or die("git add failed");
    run_program('git', @gitdir, 'commit', '-am', 'Initial commit')
        or die("git commit failed");
    run_program('git', @gitdir, 'tag', 'v5.4') or die("git tag failed");

    # Save the results in the instance
    $self->_repo_dir_token($tempdir);
    $self->lxr_repo_dir($tempdir_path);

    return $self;
} #build_repo()

=head2 build_db

Build a test database for the repository.  L</lxr_repo_dir> must be set
before calling this.  Usage:

    $tenv->build_db([$db_dir])

C<$db_dir> is the directory where you want to put the database.  If you do
not provide one, a temporary directory will be created.

Dies on error.  On success, returns the instance, for chaining.

B<CAUTION>: This function will remove the contents of C<$db_dir>
unconditionally.

=cut

sub build_db {
    my ($self, $db_dir) = @_;
    die "No repo dir" unless $self->lxr_repo_dir;

    if($db_dir) {   # Remove any existing DB dir
        remove_tree($db_dir);
        mkdir($db_dir) or die "Could not create fresh $db_dir";
    }

    # Create a temp DB dir if necessary
    my $temp_db_dir;
    unless($db_dir) {
        $temp_db_dir = tempdir(CLEANUP => 1);
        $db_dir = abs_path($temp_db_dir);
    }

    local $ENV{LXR_REPO_DIR} = $self->lxr_repo_dir;
    local $ENV{LXR_DATA_DIR} = $db_dir;

    run_program($self->update_py)
        or die "Could not create database from $ENV{LXR_REPO_DIR} in $ENV{LXR_DATA_DIR}";

    $self->_data_dir_token($temp_db_dir);
    $self->lxr_data_dir($db_dir);

    return $self;
} #build_db()

=head2 update_env

Set the C<LXR_REPO_DIR> and C<LXR_DATA_DIR> environment variables.
Will not set a variable if the corresponding member does not have a value.

Returns the instance, for chaining.

=cut

sub update_env {
    my $self = shift;
    $ENV{LXR_REPO_DIR} = $self->lxr_repo_dir if $self->lxr_repo_dir;
    $ENV{LXR_DATA_DIR} = $self->lxr_data_dir if $self->lxr_data_dir;
    return $self;
} #update_env()

=head2 DESTROY

Destructor.  Called automatically.

=cut

sub DESTROY {
    local($., $@, $!, $^E, $?);
    my $self = shift;

    # Release the temporary directories
    $self->_data_dir_token(undef);
    $self->_repo_dir_token(undef);
}

1;
__END__


=head1 AUTHOR

Christopher White, C<< <cwhite@d3engineering.com> >>

=head1 COPYRIGHT

Copyright (c) 2020 D3 Engineering, LLC.

Elixir is free software; you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Elixir is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with Elixir.  If not, see <http://www.gnu.org/licenses/>.

=cut
