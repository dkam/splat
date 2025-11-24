# Archive strategy
```ruby
class ArchiveOldEvents
  def self.perform
    # Create monthly archive
    archive_db = "storage/archive_#{Date.today.strftime('%Y_%m')}.sqlite3"
    
    ActiveRecord::Base.connection.execute(<<~SQL)
      ATTACH DATABASE '#{archive_db}' AS archive;
      
      CREATE TABLE IF NOT EXISTS archive.events AS 
        SELECT * FROM main.events WHERE 0;
      
      INSERT INTO archive.events 
        SELECT * FROM main.events 
        WHERE created_at < date('now', '-30 days');
      
      DELETE FROM main.events 
        WHERE created_at < date('now', '-30 days');
      
      DETACH DATABASE archive;
    SQL
  end
end
```