source 'http://rubygems.org'

gem 'rails', '>= 4.1.5'

gem 'mysql2', '>= 0.3.16'
gem 'sqlite3', '>= 1.3.8'

gem 'authpwn_rails', '>= 0.16.2'
gem 'configvars_rails', '>= 0.6.1'
gem 'gravatar-ultimate', '>= 2.0.0'
gem 'grit', git: 'https://github.com/pwnall/grit.git', branch: 'gitty'
gem 'markdpwn', '>= 0.2.0'
gem 'net-ssh', '>= 2.7.0', require: 'net/ssh'
gem 'posix-spawn', '>= 0.3.8'
gem 'rbtree', '>= 0.4.2', platform: :mri
gem 'rbtree-pure', '>= 0.1.1', require: 'rbtree', platforms: [:jruby, :rbx]
gem 'rugged', '>= 0.19.0', git: 'https://github.com/libgit2/rugged',
    submodules: true, ref: 'f286099b4d0c5bbcc54ae3005c6603b42a1eabd4'
    # branch: development
gem 'topological_sort', '>= 0.1.1'

# CSS gems.
gem 'sass-rails', '>= 4.0.3'
gem 'foundation-rails', '>= 5.3.3.0'
gem 'font-awesome-rails', '>= 4.1.0.0'

# JavaScript gems.
gem 'coffee-rails', '>= 4.0.1'
gem 'jquery-rails', '>= 3.1.1'
gem 'therubyracer', '>= 0.12.1', platforms: :ruby
gem 'uglifier', '>= 2.5.3'


# Memory leak debugging.
gem 'oink', '>= 0.10.1'

# Bundle gems for the local environment. Make sure to
# put test-only gems in this group so their generators
# and rake tasks are available in development mode:
group :development, :test do
  gem 'better_errors'
  gem 'binding_of_caller'
  gem 'debugger'
  gem 'railroady', '>= 1.1.2'
  gem 'thin', '>= 1.6.2'
end

group :test do
  gem 'mocha', '>= 1.1.0', require: 'mocha/setup'
end

group :production do
  gem 'thin', '>= 1.6.2'
end
