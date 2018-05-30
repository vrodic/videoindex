select file_size, count(*),filename,file_size/(1024*1024) from media group by 1 having count(*) > 1 order by 1 desc;
select round(sum(file_size)/(1024*1024*1024)) 
from (
	select file_size, count(*),filename,file_size/(1024*1024) from media group by 1 having count(*) > 1 order by 1 desc
	) as a;
select duration, count(*),filename,file_size/(1024*1024*1024) from media where duration > 60 group by 1 order by 2 desc, 4 desc;
select count(*) from media;


select * from media order by id desc limit 1000;
select sum(file_size)/(1024*1024*1024) from media;
select sum(duration/60) from media;
