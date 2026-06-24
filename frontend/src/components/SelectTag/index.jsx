import useLanguage from '@/locale/useLanguage';
import { Select } from 'antd';
import { generate as uniqueId } from 'shortid';

export default function SelectTag({ options, defaultValue }) {
  const translate = useLanguage()
  return (
    <Select
      defaultValue={defaultValue}
      style={{
        width: '100%',
      }}
    >
      {options?.map((option) => {
        if (option)
          return (
            <Select.Option key={`${uniqueId()}`} value={option.value}>
              {translate(option.label)}
            </Select.Option>
          );
        else
          return (
            <Select.Option key={`${uniqueId()}`} value={option}>
              {option}
            </Select.Option>
          );
      })}
    </Select>
  );
}
