# BetterMeans - Work 2.0
# Copyright (C) 2009  Shereef Bishay
#

require File.dirname(__FILE__) + '/../test_helper'

class IssueStatusTest < ActiveSupport::TestCase
  fixtures :issue_statuses, :issues

  def test_create
    status = IssueStatus.new :name => "Assigned"
    assert !status.save
    # status name uniqueness
    assert_equal 1, status.errors.count
    
    status.name = "Test Status"
    assert status.save
    assert !status.is_default
  end
  
  def test_destroy
    count_before = IssueStatus.count
    status = IssueStatus.find(3)
    assert status.destroy
    assert_equal count_before - 1, IssueStatus.count
  end

  def test_destroy_status_in_use
    # Status assigned to an Issue
    status = Issue.find(1).status
    assert_raise(RuntimeError, "Can't delete status") { status.destroy }
  end

  def test_default
    status = IssueStatus.default
    assert_kind_of IssueStatus, status
  end
  
  def test_change_default
    status = IssueStatus.find(2)
    assert !status.is_default
    status.is_default = true
    assert status.save
    status.reload
    
    assert_equal status, IssueStatus.default
    assert !IssueStatus.find(1).is_default
  end
  
  def test_reorder_should_not_clear_default_status
    status = IssueStatus.default
    status.move_to_bottom
    status.reload
    assert status.is_default?
  end
end


# == Schema Information
#
# Table name: issue_statuses
#
#  id         :integer         not null, primary key
#  name       :string(30)      default(""), not null
#  is_closed  :boolean         default(FALSE), not null
#  is_default :boolean         default(FALSE), not null
#  position   :integer         default(1)
#

