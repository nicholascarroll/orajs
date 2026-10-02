create table emp (
  empno number primary key,
  ename varchar2(20)
);
create or replace view emp_v as select empno, ename from emp;
