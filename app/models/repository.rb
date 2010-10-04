# Git repository hosted on this server.
class Repository < ActiveRecord::Base
  # The profile representing the repository's author.
  belongs_to :profile
  validates :profile, :presence => true
  
  # Virtual attribute, backed by profile_id.
  def profile_name
    @profile_name ||= profile && profile.name
  end
  def profile_name=(new_profile_name)
    self.profile = new_profile_name &&
        Profile.where(:name => new_profile_name).first    
    @profile_name = profile && profile.name
  end
  
  # Branch information cached from the on-disk repository.
  has_many :branches, :dependent => :destroy
  # Tag information cached from the on-disk repository.
  has_many :tags, :dependent => :destroy
  # Commit information cached from the on-disk repository.
  has_many :commits, :dependent => :destroy  
  # Tree information cached from the on-disk repository.
  has_many :trees, :dependent => :destroy  
  # Blob information cached from the on-disk repository.
  has_many :blobs, :dependent => :destroy
  has_many :acl_entries, :as => :subject, :dependent => :destroy
  
  # The repository name.
  validates :name, :length => 1..64, :format => /\A\w([\w.-]*\w)?\Z/,
                   :presence => true,
                   :uniqueness => { :scope => :profile_id }

  # The repository's location on disk.
  def local_path
    self.class.local_path profile, name
  end
  
  # The on-disk location of a repository.
  #
  # Args:
  #   profile:: the profile owning the repository
  #   name:: the repository's name
  def self.local_path(profile, name)
    File.join profile.local_path, name + '.git'
  end
  
  # The repository's URL for SSH access.
  def ssh_uri
    ssh_root = "#{ConfigVar['git_user']}@#{ConfigVar['ssh_host']}" 
    "#{ssh_root}:#{ssh_path}"
  end
  
  # The relative path in the repository's SSH access uri.
  def ssh_path
    "#{profile.name}/#{name}.git"
  end
  
  # The Grit::Repo object for this repository.
  def grit_repo
    @grit_repo ||= !(new_record? || destroyed?) && Grit::Repo.new(local_path)
  end
  
  # Use the repository name instead of ID in all routes.
  def to_param
    name
  end
  
  # The repository matching a SSH path, or nil if no such repository exists.
  #
  # This method returns nil for invalid SSH paths. Valid paths are contained in
  # ssh URIs generated by Repository#ssh_uri.
  def self.find_by_ssh_path(ssh_path)
    return nil unless match = /\A(\w+)\/(\w+)\.git\Z/.match(ssh_path)
    return nil unless repo_profile = Profile.where(:name => match[1]).first
    repo_profile.repositories.where(:name => match[2]).first
  end  
end


# :nodoc: keep on-disk repositories synchronized
class Repository
  after_create :create_local_repository
  before_save :save_old_repository_name
  after_update :relocate_local_repository
  after_destroy :delete_local_repository

  # Creates a Git repository on disk.
  def create_local_repository
    # TODO: background job.
    @grit_repo = Grit::Repo.init_bare local_path
    FileUtils.chmod_R 0770, local_path
    begin
      FileUtils.chown_R ConfigVar['git_user'], nil, local_path
    rescue ArgumentError
      # Happens in unit testing, when the git user isn't created yet.
      raise unless Rails.env.test?
    rescue Errno::EPERM
      # Not root, not allowed to chown.    
    end
    
    @grit_repo
  end
  
  # Relocates a Git repository on disk.
  def self.relocate_local_repository(profile, old_name, new_name)
    # TODO: maybe this should be a background job.
    old_path = local_path profile, old_name
    new_path = local_path profile, new_name
    FileUtils.mv old_path, new_path
  end
  
  # Saves the repository's old name, so it can be relocated.
  def save_old_repository_name
    @_old_repository_name = name_change.first if name_change
  end
  
  # Relocates the on-disk repository after the model's name is changed.
  def relocate_local_repository
    return unless old_name = @_old_repository_name
    
    self.class.relocate_local_repository profile, old_name, name
    @grit_repo = nil
  end    
  
  # Deletes the on-disk repository. 
  def delete_local_repository
    # TODO: background job.    
    FileUtils.rm_r local_path if File.exist? local_path
    @grit_repo = nil
  end
end

# :nodoc: synchronization with on-disk repositories
class Repository
  # Differences between the on-disk branches and the database models.
  #
  # Returns a hash with the following keys:
  #   :added:: array of Grit::Head objects for new branches
  #   :deleted:: array of Branch models that have been removed
  #   :changed:: hash of Branch models to Grit::Head objects for branches whose
  #              commit pointers have changed
  def branch_changes
    delta = {:added => [], :deleted => [], :changed => {}}    
    db_branches = self.branches.all.index_by(&:name)
    grit_repo.branches.each do |git_branch|
      if branch = db_branches.delete(git_branch.name)
        if branch.commit.gitid != git_branch.commit.id
          delta[:changed][branch] = git_branch
        end
      else
        delta[:added] << git_branch
      end
    end
    delta[:deleted] = db_branches.values
    delta
  end
  
  # Differences between the on-disk tags and the database models.
  #
  # Returns a hash with the following keys:
  #   :added:: array of Grit::Tag objects for new tags
  #   :deleted:: array of Tag models that have been removed
  #   :changed:: hash of Tag models to Grit::Tag objects for tags whose
  #              commit pointers have changed
  def tag_changes
    delta = {:added => [], :deleted => [], :changed => {}}    
    db_tags = self.tags.all.index_by(&:name)
    grit_repo.tags.each do |git_tag|
      if tag = db_tags.delete(git_tag.name)
        if tag.commit.gitid != git_tag.commit.id ||
            tag.message != git_tag.message ||
            tag.committed_at != git_tag.tag_date 
          delta[:changed][tag] = git_tag
        end
      else
        delta[:added] << git_tag
      end
    end
    delta[:deleted] = db_tags.values
    delta
  end
    
  
  # Commits that don't have associated database models.
  #
  # Args:
  #   git_refs:: array of Grit::Ref objects representing on-disk branches or
  #              tags used as starting points for searching for commits
  #
  # Returns an array of Grit::Commit objects, topologically sorted. This means
  # that, if the commits are created in order, a commit's parents will always
  # exist before it is created.
  def commits_added(git_refs)
    new_commits = []

    # Topological-sorting DFS for discovering new commits.    
    visited = Set.new  # Git ids for visited commits.
    stack = []  # DFS stack state. Each node is a [commit, parent_number].
    git_refs.each do |git_ref|
      next if visited.include? git_ref.commit.id
      visited << git_ref.commit.id
      next if self.commits.where(:gitid => git_ref.commit.id).first
      stack << [git_ref.commit, -1] 
      
      until stack.empty?
        stack.last[1] += 1        
        git_commit, parent_number = *stack.last
        
        if parent_git_commit = git_commit.parents[parent_number]
          unless visited.include? parent_git_commit.id
            visited << parent_git_commit.id
            unless self.commits.where(:gitid => parent_git_commit.id).first
              stack << [parent_git_commit, -1]
            end
          end
        else
          new_commits << git_commit
          stack.pop
        end
      end
    end
        
    new_commits
  end
  
  # Trees and blobs that don't have associated database models.
  #
  # Args:
  #   git_branches:: array of Grit::Head objects representing on-disk branches
  #                  used as starting points for searching for commits
  #
  # Returns a hash with the follwing keys:
  #   blobs:: array of Grit::Blob objects
  #   trees:: array of Grit::Tree objects, topologically sorted. This means
  #           that, if the trees are created in order, a tree's children will
  #           always exist before it is created.
  def contents_added(git_commits)
    blobs = []
    
    # Topological-sorting BFS.
    queue = []
    visited = Set.new
    # NOTE: yup, Grit::Commit objects with the same id aren't necessarily == 
    git_commits.each do |commit| 
      next if visited.include? commit.tree.id
      visited << commit.tree.id
      unless self.trees.where(:gitid => commit.tree.id).first
        queue << commit.tree
      end
    end
    
    i = 0
    while i < queue.length  # The queue keeps growing, so can't use each.
      tree = queue[i]
      i += 1
      
      tree.contents.each do |child|
        next if visited.include? child.id
        visited << child.id
        if child.kind_of? Grit::Blob
          blobs << child unless self.blobs.where(:gitid => child.id).first
        else
          queue << child unless self.trees.where(:gitid => child.id).first
        end
      end
    end
  
    { :blobs => blobs, :trees => queue.reverse! }
  end
  
  # Integrates changes to the on-disk repository into the database.
  #
  # Returns a hash with the following keys:
  #   :commits:: set of Commit models created from the on-disk repository
  #   :branches:: hash with the following keys:
  #                 added:: array of Branch models created from the on-disk
  #                         repository
  #                 changed:: array of Branch models whose head commit changed
  #                 deleted: array of Branch models removed from the on-disk
  #                          repository
  def integrate_changes
    changes = {}
    
    branch_delta = self.branch_changes
    tag_delta = self.tag_changes
    changed_git_refs = branch_delta[:added] + branch_delta[:changed].values +
                       tag_delta[:added] + tag_delta[:changed].values
    new_git_commits = self.commits_added changed_git_refs
    new_contents = self.contents_added new_git_commits
    
    new_contents[:blobs].each do |git_blob|
      Blob.from_git_blob(git_blob, self).save!
    end
    new_contents[:trees].each do |git_tree|
      tree = Tree.from_git_tree(git_tree, self)
      tree.save!
      
      tree_entries = TreeEntry.from_git_tree git_tree, self, tree
      tree_entries.each &:save!
    end
    new_commits = Set.new
    new_git_commits.each do |git_commit|
      commit = Commit.from_git_commit(git_commit, self)
      commit.save!
      new_commits << commit

      commit_parents = CommitParent.from_git_commit git_commit, self, commit
      commit_parents.each &:save!
    end
    new_branches = []
    branch_delta[:added].each do |git_branch|
      branch = Branch.from_git_branch(git_branch, self)
      branch.save!
      new_branches << branch
    end
    changed_branches = []
    branch_delta[:changed].each do |branch, git_branch|
      branch = Branch.from_git_branch(git_branch, self, branch)
      branch.save!
      changed_branches << branch
    end    
    branch_delta[:deleted].each { |branch| branch.destroy }
    new_tags = []
    tag_delta[:added].each do |git_tag|
      tag = Tag.from_git_tag(git_tag, self)
      tag.save!
      new_tags << tag
    end
    changed_tags = []
    tag_delta[:changed].each do |tag, git_tag|
      tag = Tag.from_git_tag(git_tag, self, tag)
      tag.save!
      changed_tags << tag
    end    
    tag_delta[:deleted].each { |tag| tag.destroy }
    
    { :commits => new_commits,
      :branches => { :added => new_branches, :changed => changed_branches,
                     :deleted => branch_delta[:deleted] },
      :tags => { :added => new_tags, :changed => changed_tags,
                 :deleted => tag_delta[:deleted] } }
  end
end

# :nodoc: access control
class Repository
  # True if the user can read the repository.
  #
  # Reading implies git pull rights.
  def can_read?(user)
    can_x? user, [:read, :commit, :edit], [:participate, :charge, :edit]
  end
  
  # True if the user can commit to the repository.
  #
  # Committing means the user can push branches and tags.
  def can_commit?(user)
    can_x? user, [:commit, :edit], [:participate, :charge, :edit]
  end
  
  # True if the user can edit (administrate) the repository.
  #
  # Administrating implies changing the repository ACL, as well as renaming and
  # deleting the repository. 
  def can_edit?(user)
    # NOTE: users who can charge the profile can always edit the repo by
    #       deleting it and creating a similar repo with the same name 
    can_x? user, [:edit], [:charge, :edit]
  end
  
  def can_x?(user, profile_role, user_role)
    return false if !user
    profile_ids = user.acl_entries.
        where(:role => user_role, :subject_type => 'Profile').map(&:subject_id)
    acl_entries.exists?(:role => profile_role, :principal_type => 'Profile',
                        :principal_id => profile_ids)
  end
  
  private :can_x?
end

# :nodoc: almost-UI
class Repository
  # The repository branch shown if no other branch is specified.
  def default_branch
    branches.where(:name => 'master').first || branches.first
  end
end

# :nodoc: set up an ACL entry for the repository
class Repository
  before_save :save_old_profile
  after_save :add_acl_entry
  
  # Saves the user's current profile for the post-save ACL fixup.
  def save_old_profile
    @_old_profile_id = profile_id_change ? profile_id_change.first : false
    true
  end
  
  # Creates an ACL entry for the user's profile.
  def add_acl_entry
    return if @_old_profile_id == false
    
    old_profile = @_old_profile_id && Profile.find(@_old_profile_id)
    AclEntry.set old_profile, self, nil if old_profile
    AclEntry.set profile, self, :edit if profile
  end
end
