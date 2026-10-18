export default {
  type: 'form',
  fields: [
    { key: 'day', label: '日期', type: 'date', required: 'true', placeholder: '' },
    { key: 'note', label: '备注', type: 'text', required: 'false', placeholder: '' },
  ],
  submit: { action: 'api', method: 'POST', path: '' },
};
