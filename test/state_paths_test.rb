# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require "adventure_finder_state_paths"

# Exercises read-only namespace admission independently of owner runtimes.
class StatePathsTest < Minitest::Test
  Paths = AdventureFinderWorkspace::StatePaths

  # Creates sibling code, owner and state directories without production suffixes.
  def setup
    @temporary = Dir.mktmpdir("af-state-paths")
    @front = File.join(@temporary, "front")
    @state = File.join(@temporary, "state")
    @owner = File.join(@temporary, "owner")
    FileUtils.mkdir_p([@front, @state, @owner])
  end

  # Removes only this test's isolated directories, including mode-refusal fixtures.
  def teardown
    File.chmod(0o700, @state)
    FileUtils.remove_entry(@temporary)
  end

  # Unset selection preserves the legacy root; valid selection creates nothing.
  def test_legacy_and_external_selection_leave_bytes_unchanged
    assert_equal Pathname(@front), Paths.root(front_door_root: @front, env: {})
    assert_equal Pathname(@state), selected
    assert_empty Dir.children(@state)
    assert_equal @state, Paths.binding(selected).fetch("root")
  end

  # Invalid explicit selectors never fall back, including symlinked ancestors.
  def test_invalid_selectors_refuse_without_creating_state
    link = File.join(@temporary, "link")
    File.symlink(@state, link)
    ["", "state", @state + "/../state", @state + "/./", @state + "/missing", link].each do |value|
      assert_raises(AdventureFinderWorkspace::Error) { selected(value) }
      assert_empty Dir.children(@state)
    end
    File.chmod(0o500, @state)
    assert_raises(AdventureFinderWorkspace::Error) { selected }
  end

  # Both containment directions and aliased owner roots refuse; common parents
  # of sibling roles remain valid and are not selected roles themselves.
  def test_role_overlap_and_symlinked_owner_aliases_refuse
    [@front, File.join(@front, "nested"), @temporary, @owner].each do |value|
      FileUtils.mkdir_p(value)
      assert_raises(AdventureFinderWorkspace::Error) { selected(value) }
    end
    link = File.join(@temporary, "owner-link")
    File.symlink(@state, link)
    assert_raises(AdventureFinderWorkspace::Error) do
      Paths.root(front_door_root: @front, owner_roots: [link], env: {"AF_STATE_ROOT" => @state})
    end
    assert_equal Pathname(@state), selected
  end

  # Family collisions and operation descendants are checked before publication.
  def test_destination_collisions_and_symlinks_refuse
    FileUtils.mkdir_p(File.join(@state, "output"))
    File.write(File.join(@state, "output", "ingest-contexts"), "foreign")
    assert_raises(AdventureFinderWorkspace::Error) { selected }
    File.unlink(File.join(@state, "output", "ingest-contexts"))
    path = File.join(@state, "output/ingest-contexts/v0.1")
    FileUtils.mkdir_p(path)
    File.symlink(@owner, File.join(path, "handle.json"))
    assert_raises(AdventureFinderWorkspace::Error) { Paths.check_operation!(selected, "handle") }
    assert_empty Dir.children(@owner)
  end

  private

  # Resolves a selector with explicit sibling owner data; invalid inputs raise Error.
  def selected(value = @state)
    Paths.root(front_door_root: @front, project_root: @temporary, owner_roots: [@owner],
               env: {"AF_STATE_ROOT" => value})
  end
end
