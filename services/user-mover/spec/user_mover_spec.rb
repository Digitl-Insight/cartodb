require_relative '../../../spec/spec_helper.rb'
require_relative '../import_user'
require_relative '../export_user'

RSpec.configure do |c|
  c.include Helpers
end
describe CartoDB::DataMover::ExportJob do

  before :each do
    CartoDB::NamedMapsWrapper::NamedMaps.any_instance.stubs(:get => nil, :create => true, :update => true, :delete => true)
    @tmp_path = Dir.mktmpdir("mover-test") + '/'
  end

  let(:first_user) { 
      create_user(
        :quota_in_bytes => 100.megabyte,
        :private_tables_enabled => true,
        :database_timeout => 123450,
        :user_timeout => 456780
      )
  }

  shared_examples "a migrated user" do

    it "has expected statement_timeout" do
      expect(subject.in_database['SHOW statement_timeout'].to_a[0][:statement_timeout]).to eq("456780ms")
      expect(subject.in_database(as: :public_db_user)['SHOW statement_timeout'].to_a[0][:statement_timeout]).to eq("123450ms")
    end

    it "keeps proper table privacy" do
      check_tables(subject)
    end
  end

  describe "a migrated user" do
    subject do
      create_tables(first_user)
      first_user.save
      move_user(first_user)
    end

    it_behaves_like "a migrated user"
    it "matches old and new user" do
      expect((first_user.as_json.reject{|x| x == :updated_at})).to eq((subject.as_json.reject{|x| x == :updated_at}))
    end
  end

  describe "a standalone user which has moved to an organization" do
    before(:all) do
      @org = create_organization_with_users
    end

    subject do
      create_tables(first_user)
      first_user.move_to_own_schema

      CartoDB::DataMover::ExportJob.new(id: first_user.username, path: @tmp_path, schema_mode: true)
      User.terminate_database_connections(first_user.database_name, first_user.database_host)
      CartoDB::DataMover::ImportJob.new(file: @tmp_path + "user_#{first_user.id}.json", mode: :rollback, drop_database: true, drop_roles: true).run!
      CartoDB::DataMover::ImportJob.new(file: @tmp_path + "user_#{first_user.id}.json", mode: :import, target_org: @org.name).run!

      moved_user = User.find(username: first_user.username)
      moved_user.link_ghost_tables
      moved_user
    end
    
    it_behaves_like "a migrated user"

    it "matches old and new user except database_name" do
      p first_user.as_json.reject!{|x| x == :updated_at}
      p subject.as_json.reject!{|x| x == :updated_at}
      expect(first_user.as_json.reject{|x| [:updated_at, :database_name, :organization_id].include? x}).to eq(subject.as_json.reject{|x| [:updated_at, :database_name, :organization_id].include? x})
      expect(subject.database_name).to eq(@org.owner.database_name)
      expect(subject.organization_id).to eq(@org.id)
    end

    it "has granted the org role" do
      authed_roles = subject.in_database["select s.rolname from pg_roles r join pg_catalog.pg_auth_members m on r.oid=m.member join pg_catalog.pg_roles s on m.roleid=s.oid where r.rolname='#{subject.database_username}'"].to_a
      authed_roles.should have(2).items
      authed_roles.should be_any{|m| m[:rolname] =~ /cdb_org_member_(.*)/ }
    end

  end


  it "should move a user from an organization to its own account" do
    org = create_organization_with_users
    user = create_user(
      :quota_in_bytes => 100.megabyte, :table_quota => 400, :organization => org
    )
    org.reload
    create_tables(user)

    CartoDB::DataMover::ExportJob.new(id: user.username, path: @tmp_path, schema_mode: true)
    User.terminate_database_connections(user.database_name, user.database_host)
    CartoDB::DataMover::ImportJob.new(file: @tmp_path + "user_#{user.id}.json", mode: :rollback).run!
    CartoDB::DataMover::ImportJob.new(file: @tmp_path + "user_#{user.id}.json", mode: :import).run!

    moved_user = User.find(username: user.username)
    moved_user.link_ghost_tables
    check_tables(moved_user)
    moved_user.organization_id.should eq nil
  end

  it "should move a whole organization" do
    org = create_organization_with_users
    user = create_user(
      :quota_in_bytes => 100.megabyte, :table_quota => 400, :organization => org
    )
    user.save
    org.reload

    create_tables(org.owner)
    share_tables(org.owner, user)
    share_tables(user, org.owner)
    create_tables(user)

    carto_org = Carto::Organization.find(org.id)

    group_1 = carto_org.create_group(String.random(5))
    group_2 = carto_org.create_group(String.random(5))

    group_1.add_user(org.owner.username)
    group_2.add_user(org.owner.username)
    group_1.add_user(user.username)
    group_2.add_user(user.username)

    share_group_tables(org.owner, group_1)
    share_group_tables(user, group_2)

    CartoDB::DataMover::ExportJob.new(organization_name: org.name, path: @tmp_path)
    User.terminate_database_connections(org.owner.database_name, org.owner.database_host)
    CartoDB::DataMover::ImportJob.new(file: @tmp_path + "org_#{org.id}.json", mode: :rollback, drop_database: true, drop_roles: true).run!
    CartoDB::DataMover::ImportJob.new(file: @tmp_path + "org_#{org.id}.json", mode: :import).run!

    moved_user = User.find(username: user.username)
    moved_user.link_ghost_tables
    check_tables(moved_user)
    moved_user.organization_id.should_not eq nil
  end

end

module Helpers
  def move_user(user)
    CartoDB::DataMover::ExportJob.new(id: user.username, path: @tmp_path)
    User.terminate_database_connections(user.database_name, user.database_host)
    CartoDB::DataMover::ImportJob.new(file: @tmp_path + "user_#{user.id}.json", mode: :rollback, drop_database: true).run!
    CartoDB::DataMover::ImportJob.new(file: @tmp_path + "user_#{user.id}.json", mode: :import).run!
    return User.find(username: user.username)
  end

  def create_tables(user)
    create_table(user_id: user.id, name: "with_link", privacy: UserTable::PRIVACY_LINK)
    create_table(user_id: user.id, name: "public",    privacy: UserTable::PRIVACY_PUBLIC)
    create_table(user_id: user.id, name: "private",   privacy: UserTable::PRIVACY_PRIVATE)
  end

  def share_tables(user1, user2)
    table_ro = create_table(user_id: user1.id, name: "shared_ro_by_#{user1.username}_to_#{user2.id}", privacy: UserTable::PRIVACY_PRIVATE)
    give_permission(table_ro.table_visualization, user2, CartoDB::Permission::ACCESS_READONLY)
    table_rw = create_table(user_id: user1.id, name: "shared_rw_by_#{user1.username}_to_#{user2.id}", privacy: UserTable::PRIVACY_PRIVATE)
    give_permission(table_rw.table_visualization, user2, CartoDB::Permission::ACCESS_READWRITE)
  end
  def share_group_tables(user, group)
    table_ro = create_table(user_id: user.id, name: "shared_ro_by_#{user.username}_to_#{group.name}", privacy: UserTable::PRIVACY_PRIVATE)
    give_group_permission(table_ro.table_visualization, group, CartoDB::Permission::ACCESS_READONLY)
    table_rw = create_table(user_id: user.id, name: "shared_rw_by_#{user.username}_to_#{group.name}", privacy: UserTable::PRIVACY_PRIVATE)
    give_group_permission(table_rw.table_visualization, group, CartoDB::Permission::ACCESS_READWRITE)
  end

  def check_tables(moved_user)
    Table.new(user_table: moved_user.tables.where(name: "private").first).privacy.should   eq UserTable::PRIVACY_PRIVATE
    Table.new(user_table: moved_user.tables.where(name: "public").first).privacy.should    eq UserTable::PRIVACY_PUBLIC
    Table.new(user_table: moved_user.tables.where(name: "with_link").first).privacy.should eq UserTable::PRIVACY_LINK
  end

  def create_organization_with_users
    org = create_organization(name: String.random(5).downcase, quota_in_bytes: 2500.megabytes)

    owner = create_user(username: String.random(5).downcase, quota_in_bytes: 500.megabytes, table_quota: 200,
                        :private_tables_enabled => true)
    uo = CartoDB::UserOrganization.new(org.id, owner.id)
    uo.promote_user_to_admin
    org.reload
    return org
  end


  def give_permission(vis, user, access)
    per = vis.permission
    per.set_user_permission(user, access)
    per.save
    per.reload
  end

  def give_group_permission(vis, user, access)
    per = vis.permission
    per.set_group_permission(user, access)
    per.update_db_group_permission = true
    per.save
    per.reload
  end
end
