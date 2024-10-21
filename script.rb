require 'net/http'
require 'json'
require 'uri'
require 'octokit'
require 'debug'
require 'optparse'
require 'dotenv/load'
require 'base64'
require 'fileutils'
require 'tmpdir'

client = Octokit::Client.new(access_token: "#{ENV['GHEC_TOKEN']}")

# The argument is the repo that contains PRs based on forks
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: script.rb [options]"

  opts.on("-rREPO", "--repo=REPO", "Repo with fork compare PR") do |r|
    options[:repo] = r
  end
end.parse!

source_repo = options[:repo]
# This will be the target org where all forks are created
target_org = ENV["TARGET_ORG"]

# With a hash as input, rebuild the original PR

def create_pull_request_review_comments(source_pr, new_pr, client, source_repo)
  # Grab all .pull_request_comments for the source PR
  # From the comment list, extract the ones that _don't_ have the in_reply_to_id key. Make a seperate array of hashes
  #   Loop through the array of hashes and fetch the review_id for each comment
  #   Get the path, position, and body for each comment from source
  #   Using these values and the review_id, create a new comment
  
  # In the API, pull_request_comments are attached to some review thread
  pr_comments = client.pull_request_comments("#{source_repo}", source_pr[:number]).map do |c|
    {
      comment_id: c.id,
      body: c.body,
      commit_id: c.commit_id,
      path: c.path,
      position: c.position,
      pr_review_id: c.pull_request_review_id,
      in_reply_to_id: c.fetch(:in_reply_to_id, nil)
    }
  end
  # Parent comments have some state associated (i.e. changes requested, approved, etc.)
  parent_comments = pr_comments.select { |c| c[:in_reply_to_id].nil? }
  parent_comments.each do |p|
    comments = []
    c_hash = {}
    
    review_state = client.pull_request_review(source_repo, source_pr[:number], p[:pr_review_id]).state
    case review_state
    # The API expects the imperative tense: https://docs.github.com/en/rest/pulls/reviews?apiVersion=2022-11-28#create-a-review-for-a-pull-request
    when "APPROVED"
      review_state = "APPROVE"
    when "CHANGES_REQUESTED"
      review_state = "REQUEST_CHANGES"
    when "COMMENTED"
      review_state = "COMMENT"
    end
    
    c_hash[:path] = p[:path]
    c_hash[:position] = p[:position]
    c_hash[:body] = p[:body]
    # Get rid of metadata if it's nil
    c_hash = c_hash.select { |_, value| !value.nil? }
    comments << c_hash
    options = { event: review_state, comments: comments }

    # From the pr_comments array, select any comments that have the same comment_id as the parent comment
    c_comments = pr_comments.select { |c| c[:in_reply_to_id] == p[:comment_id] }
    parent_r_id = client.create_pull_request_review(source_repo, new_pr[:number], options).id
    new_parent_comments = client.pull_request_comments(source_repo, new_pr[:number]).select { |c| c.pull_request_review_id == parent_r_id }
    # For now, we just need that parent comment's id
    parent_c_id = new_parent_comments.first.id
    if parent_c_id
      c_comments.each do |comment|
        client.create_pull_request_comment_reply(source_repo, new_pr[:number], comment[:body], parent_c_id)
      end
    end
  end
end

def rebuild_prs(pr_arr, client, source_repo, target_org, forked_repo_fn)
  pr_arr.each do |pr|
    begin
      # close the original PR
      puts "Rebuilding new PRs..."
      target_pr = client.create_pull_request("#{source_repo}", "main", "#{forked_repo_fn}:#{pr[:ref]}", "#{pr[:title]}", "#{pr[:body]}")
      create_pull_request_review_comments(pr, target_pr, client, source_repo)
      puts "Closing the original PRs from the migration..."
      #closed_pr = client.close_pull_request("#{source_repo}", pr[:number])
      # ensure that it's closed
      if closed_pr.state == "closed"
        # Check for a matching ref in the forked repo
        puts "Rebuilding PR with the new fork in #{forked_repo_fn}..."  
        
        # This checking of refs shouldn't be necessary, or at least it should be done in the rebuild_commits method
        # any_forked_refs = client.refs("#{target_org/forked_repo}").any?{ |ref| ref.ref == "refs/heads/#{pr[:ref]}" }

        # Need to get the base ref inputted, but now, stubbing main
        client.create_pull_request("#{source_repo}", "main", "#{forked_repo_fn}:#{pr[:ref]}", "#{pr[:title]}", "#{pr[:body]}")
      end
    rescue => e
      puts "An error occurred while processing PR ##{pr[:number]}: #{e.message}"
    end
  end
end

# Create the fork and the changes in the fork that were in the original PR compare
def rebuild_commits(pr_arr, client, source_repo, target_org)
  # Create the fork in the target org. This is necessary to rebuild commits. The login: key supports user and org namespaces
  forked_repo_fn = client.fork("#{source_repo}", organization: "#{target_org}").full_name
  forked_repo = forked_repo_fn.split("/").last
  # Conservatively give the fork a few seconds to be created
  sleep 10
  puts "Rebuilding commits in #{forked_repo}..."
  Dir.mktmpdir do |dir|
    begin
      clone_dir = File.join(dir, forked_repo)
      system ("git clone https://#{ENV["GHEC_TOKEN"]}@github.com/#{source_repo}.git #{clone_dir}")
      # change to the cloned repository's directory
      Dir.chdir(clone_dir) do
        # Perform the git operations
        system("git remote add fork https://#{ENV["GHEC_TOKEN"]}@github.com/#{forked_repo_fn}.git")
        pr_arr.each do |pr|
          # This should probably look at the incoming base ref instead of by-name 
          if pr[:ref] != "main" && pr[:ref] != "master"
            system("git fetch origin #{pr[:sha]}")
            system("git checkout -b #{pr[:ref]} #{pr[:sha]}")
            system("git push fork #{pr[:ref]}")
          elsif pr[:ref] == "main" || pr[:ref] == "master"
            system("git fetch origin #{pr[:sha]}")
            system("git checkout -b main-#{forked_repo} #{pr[:sha]}")
            system("git push fork main-#{forked_repo}")

            # ❗Update the original ref to the new ref from the fork
            pr[:ref] = "main-#{forked_repo}"
          end
        end
      end
    rescue => e
      puts "An error occurred: #{e.message}"      
    end
  end
  rebuild_prs(pr_arr, client, source_repo, forked_repo_fn, target_org)
end

if source_repo
  pr_arr = []
  # Grab only the PRs that are based on forks
  prs = client.pull_requests("#{source_repo}")
  puts "Grabbing source PRs..."
  prs.each do |pr|
    labels = client.labels_for_issue("#{source_repo}", pr.number)
    fork_label = labels.any?{ |i| i.name == "fork_compare" }
    # Check that the PR tag name also exists as a branch in the repo
    #matching_ref = client.branches("#{source_repo}").any?{ |branch| branch.name == pr.head.ref }
    # Validate two things: 1) we have the right fork label on the PR and 2) that the label was migrated as a branch to the fork
    if fork_label #&& matching_ref
      pr_hash = {}
      # New attribtutes, the PR itself and main comments
      pr_hash[:body] = pr.body
      pr_hash[:title] = pr.title
      pr_hash[:number] = pr.number
      pr_hash[:comments] = client.issue_comments(source_repo, pr.number).map { |comment| { body: comment.body, comment_id: comment.id, user: comment.user.login, reactions: comment.reactions } }
      pr_hash[:review_comments] = client.pull_request_comments(source_repo, pr.number).map { |comment| { comment_id: comment.id, pr_review_id: comment.pull_request_review_id, path: comment.path, position: comment.position, body: comment.body, reactions: comment.reactions, in_reply_to_id: comment.fetch(:in_reply_to_id, nil) } }
      # We need to grab a few things as they related to comments: 
      # - General PR comments (.issue_comments)
      # - PR review comments (.pull_request_comments)
      #   - The state of each review comment  
      #pr_hash[:general_comments] = client.issue_comments(source_repo, pr.number).map { |comment| { body: comment.body, comment_id: comment.id, user: comment.user.login, reactions: comment.reactions } }
      #pr_hash[:review_comments] = client.pull_request_comments(source_repo, pr.number).map { |comment| { body: comment.body, comment_id: comment.id, user: comment.user.login, reactions: comment.reactions, state: comment.state } }
      
      pr_hash[:repo] = pr.head.repo.full_name
      pr_hash[:label] = pr.head.label
      pr_hash[:ref] = pr.head.ref # This is the branch name
      pr_hash[:sha] = pr.head.sha
      pr_hash[:link] = pr._links.html.href
      pr_arr << pr_hash
    end
  end
  # Create the fork and rebuild the commits in the target org
  rebuild_commits(pr_arr, client, source_repo, target_org)
end