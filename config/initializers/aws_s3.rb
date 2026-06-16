# Only open an S3 connection when credentials are actually provided via the
# environment. (The previously hard-coded keys here were long dead and caused
# boot to fail; never commit live AWS keys to source control.)
if ENV['S3_ACCESS_KEY_ID'].to_s != '' && ENV['S3_SECRET_ACCESS_KEY'].to_s != ''
  AWS::S3::Base.establish_connection!(
    :access_key_id     => ENV['S3_ACCESS_KEY_ID'],
    :secret_access_key => ENV['S3_SECRET_ACCESS_KEY']
  )
end
